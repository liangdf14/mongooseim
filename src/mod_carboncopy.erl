%%%----------------------------------------------------------------------
%%% File    : mod_carboncopy.erl
%%% Author  : Eric Cestari <ecestari@process-one.net>
%%% Purpose : Message Carbons XEP-0280 0.8
%%% Created : 5 May 2008 by Mickael Remond <mremond@process-one.net>
%%% Usage   : Add `mod_carboncopy` to the `modules` section of mongooseim.toml
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2014   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------
-module (mod_carboncopy).
-author ('ecestari@process-one.net').
-xep([{xep, 280}, {version, "0.6"}]).
-xep([{xep, 280}, {version, "0.13.3"}]).
-behaviour(gen_mod).
-behaviour(mongoose_module_metrics).

%% API
-export([start/2,
         stop/1,
         supported_features/0,
         config_spec/0,
         is_carbon_copy/1]).

%% Hooks
-export([disco_local_features/3,
         user_send_packet/4,
         user_receive_packet/5,
         iq_handler2/5,
         iq_handler1/5,
         remove_connection/5
        ]).

%% Tests
-export([should_forward/3]).

-ignore_xref([is_carbon_copy/1, remove_connection/5,
              should_forward/3, user_receive_packet/5, user_send_packet/4]).

-define(CC_KEY, 'cc').

-include("mongoose.hrl").
-include("jlib.hrl").
-include("session.hrl").
-include("mongoose_config_spec.hrl").

-type direction() :: sent | received.

supported_features() -> [dynamic_domains].

is_carbon_copy(Packet) ->
    case xml:get_subtag(Packet, <<"sent">>) of
        #xmlel{name = <<"sent">>, attrs = AAttrs}  ->
            case xml:get_attr_s(<<"xmlns">>, AAttrs) of
                ?NS_CC_2 -> true;
                ?NS_CC_1 -> true;
                _ -> false
            end;
        _ -> false
    end.

%% Default IQDisc is no_queue:
%% executes disable/enable actions in the c2s process itself
start(HostType, #{iqdisc := IQDisc}) ->
    ejabberd_hooks:add(legacy_hooks(HostType)),
    gen_hook:add_handlers(hooks(HostType)),
    gen_iq_handler:add_iq_handler_for_domain(HostType, ?NS_CC_2, ejabberd_sm,
                                             fun ?MODULE:iq_handler2/5, #{}, IQDisc),
    gen_iq_handler:add_iq_handler_for_domain(HostType, ?NS_CC_1, ejabberd_sm,
                                             fun ?MODULE:iq_handler1/5, #{}, IQDisc).

stop(HostType) ->
    ejabberd_hooks:delete(legacy_hooks(HostType)),
    gen_hook:delete_handlers(hooks(HostType)),
    gen_iq_handler:remove_iq_handler_for_domain(HostType, ?NS_CC_1, ejabberd_sm),
    gen_iq_handler:remove_iq_handler_for_domain(HostType, ?NS_CC_2, ejabberd_sm),
    ok.

legacy_hooks(HostType) ->
    [{unset_presence_hook, HostType, ?MODULE, remove_connection, 10},
     {user_send_packet, HostType, ?MODULE, user_send_packet, 89},
     {user_receive_packet, HostType, ?MODULE, user_receive_packet, 89}].

hooks(HostType) ->
    [{disco_local_features, HostType, fun ?MODULE:disco_local_features/3, #{}, 99}].

-spec config_spec() -> mongoose_config_spec:config_section().
config_spec() ->
    #section{items = #{<<"iqdisc">> => mongoose_config_spec:iqdisc()},
             defaults = #{<<"iqdisc">> => no_queue}}.

-spec disco_local_features(mongoose_disco:feature_acc(),
                           map(),
                           map()) -> {ok, mongoose_disco:feature_acc()}.
disco_local_features(Acc = #{node := <<>>}, _, _) ->
    NewAcc = mongoose_disco:add_features([?NS_CC_1, ?NS_CC_2, ?NS_CC_RULES], Acc),
    {ok, NewAcc};
disco_local_features(Acc, _, _) ->
    {ok, Acc}.

iq_handler2(Acc, From, _To, IQ, _Extra) ->
    iq_handler(Acc, From, IQ, ?NS_CC_2).
iq_handler1(Acc, From, _To, IQ, _Extra) ->
    iq_handler(Acc, From, IQ, ?NS_CC_1).

iq_handler(Acc, From, #iq{type = set,
                          sub_el = #xmlel{name = Operation,
                                          children = []}} = IQ, CC) ->
    ?LOG_DEBUG(#{what => cc_iq_received, acc => Acc}),
    Result = case Operation of
                 <<"enable">> ->
                     enable(From, CC);
                 <<"disable">> ->
                     disable(From)
             end,
    case Result of
        ok ->
            ?LOG_DEBUG(#{what => cc_iq_result, acc => Acc}),
            {Acc, IQ#iq{type = result, sub_el = []}};
        {error, Reason} ->
            ?LOG_WARNING(#{what => cc_iq_failed, acc => Acc, reason => Reason}),
            {Acc, IQ#iq{type = error, sub_el = [mongoose_xmpp_errors:not_allowed()]}}
    end;

iq_handler(Acc, _From, IQ, _CC) ->
    {Acc, IQ#iq{type = error, sub_el = [mongoose_xmpp_errors:bad_request()]}}.

user_send_packet(Acc, From, To, Packet) ->
    check_and_forward(Acc, From, To, Packet, sent),
    Acc.

user_receive_packet(Acc, JID, _From, To, Packet) ->
    check_and_forward(Acc, JID, To, Packet, received),
    Acc.

remove_connection(Acc, LUser, LServer, LResource, _Status) ->
    JID = jid:make_noprep(LUser, LServer, LResource),
    disable(JID),
    Acc.

% Check if the traffic is local.
% Modified from original version:
% - registered to the user_send_packet hook, to be called only once even for multicast
% - do not support "private" message mode, and do not modify the original packet in any way
% - we also replicate "read" notifications
-spec check_and_forward(mongoose_acc:t(), jid:jid(), jid:jid(), exml:element(), direction()) -> ok | stop.
check_and_forward(Acc, JID, To, #xmlel{name = <<"message">>} = Packet, Direction) ->
    case should_forward(Packet, To, Direction) of
        false -> stop;
        true -> send_copies(Acc, JID, To, Packet, Direction)
    end;
check_and_forward(_Acc, _JID, _To, _Packet, _) -> ok.

%%%===================================================================
%%% Classification
%%%===================================================================

-spec should_forward(exml:element(), jid:jid(), direction()) -> boolean().
should_forward(Packet, To, Direction) ->
    (not is_carbon_private(Packet)) andalso
    (not has_nocopy_hint(Packet)) andalso
    (not is_received(Packet)) andalso
    (not is_sent(Packet)) andalso
    (is_chat(Packet) orelse is_valid_muc(Packet, To, Direction)).

-spec is_chat(exml:element()) -> boolean().
is_chat(Packet) ->
    case exml_query:attr(Packet, <<"type">>, <<"normal">>) of
        <<"normal">> -> contains_body(Packet) orelse
                        contains_receipts(Packet) orelse
                        contains_csn(Packet);
        <<"chat">> -> true;
        _ -> false
    end.

-spec is_valid_muc(exml:element(), jid:jid(), direction()) -> boolean().
is_valid_muc(_, _, sent) ->
    false;
is_valid_muc(Packet, To, _) ->
    is_mediated_invitation(Packet) orelse
    is_direct_muc_invitation(Packet) orelse
    is_received_private_muc(Packet, To).

-spec is_mediated_invitation(exml:element()) -> boolean().
is_mediated_invitation(Packet) ->
    undefined =/= exml_query:path(Packet,
                                  [{element_with_ns, <<"x">>, ?NS_MUC_USER},
                                   {element, <<"invite">>},
                                   {attr, <<"from">>}]).

-spec is_direct_muc_invitation(exml:element()) -> boolean().
is_direct_muc_invitation(Packet) ->
    undefined =/= exml_query:subelement_with_name_and_ns(Packet, <<"x">>, ?NS_CONFERENCE).

-spec is_received_private_muc(exml:element(), jid:jid()) -> boolean().
is_received_private_muc(_, #jid{lresource = <<>>}) ->
    false;
is_received_private_muc(Packet, _) ->
    undefined =/= exml_query:subelement_with_name_and_ns(Packet, <<"x">>, ?NS_MUC_USER).

-spec has_nocopy_hint(exml:element()) -> boolean().
has_nocopy_hint(Packet) ->
    undefined =/= exml_query:subelement_with_name_and_ns(Packet, <<"no-copy">>, ?NS_HINTS).

-spec contains_body(exml:element()) -> boolean().
contains_body(Packet) ->
    undefined =/= exml_query:subelement(Packet, <<"body">>).

-spec contains_receipts(exml:element()) -> boolean().
contains_receipts(Packet) ->
    undefined =/= exml_query:subelement_with_name_and_ns(Packet, <<"received">>, ?NS_RECEIPTS).

-spec contains_csn(exml:element()) -> boolean().
contains_csn(Packet) ->
    undefined =/= exml_query:subelement_with_ns(Packet, ?NS_CHATSTATES).

-spec is_carbon_private(exml:element()) -> boolean().
is_carbon_private(Packet) ->
    [] =/= subelements_with_nss(Packet, <<"private">>, carbon_namespaces()).

-spec is_received(exml:element()) -> boolean().
is_received(Packet) ->
    [] =/= subelements_with_nss(Packet, <<"received">>, carbon_namespaces()).

-spec is_sent(exml:element()) -> boolean().
is_sent(Packet) ->
    [] =/= subelements_with_nss(Packet, <<"sent">>, carbon_namespaces()).

-spec subelements_with_nss(exml:element(), binary(), [binary()]) -> [exml:element()].
subelements_with_nss(#xmlel{children = Children}, Name, NSS) ->
    lists:filter(fun(#xmlel{name = N} = Child) when N =:= Name ->
                        NS = exml_query:attr(Child, <<"xmlns">>),
                        lists:member(NS, NSS);
                    (_) ->
                        false
                 end, Children).

carbon_namespaces() -> [?NS_CC_1, ?NS_CC_2].

%%%===================================================================
%%% Internal
%%%===================================================================


%%
%% Internal
%%
is_bare_to(Direction, To, _PrioRes) ->
    case {Direction, To} of
        {received, #jid{lresource = <<>>}} -> true;
        _ -> false
    end.

max_prio(PrioRes) ->
    case catch lists:max(PrioRes) of
        {Prio, _Res} -> Prio;
        _ -> 0
    end.

is_max_prio(Res, PrioRes) ->
    lists:member({max_prio(PrioRes), Res}, PrioRes).

jids_minus_max_priority_resource(JID, CCResList, PrioRes) ->
    [ {jid:replace_resource(JID, CCRes), CCVersion}
      || {CCVersion, CCRes} <- CCResList, not is_max_prio(CCRes, PrioRes) ].

jids_minus_specific_resource(JID, R, CCResList, _PrioRes) ->
    [ {jid:replace_resource(JID, CCRes), CCVersion}
      || {CCVersion, CCRes} <- CCResList, CCRes =/= R ].

%% Direction = received | sent <received xmlns='urn:xmpp:carbons:1'/>
send_copies(Acc, JID, To, Packet, Direction) ->
    #jid{lresource = R} = JID,
    {PrioRes, CCResList} = get_cc_enabled_resources(JID),
    Targets = case is_bare_to(Direction, To, PrioRes) of
                  true -> jids_minus_max_priority_resource
                            (JID, CCResList, PrioRes);
                  _    -> jids_minus_specific_resource(JID, R, CCResList, PrioRes)
              end,
    ?LOG_DEBUG(#{what => cc_send_copies,
                 targets => Targets, resources => PrioRes, ccenabled => CCResList}),
    lists:foreach(fun({Dest, Version}) ->
                          ?LOG_DEBUG(#{what => cc_forwarding,
                                       user => JID#jid.luser, server => JID#jid.lserver,
                                       resource => JID#jid.lresource, exml_packet => Packet}),
                          Sender = jid:to_bare(JID),
                          New = build_forward_packet(Acc, JID, Packet, Sender, Dest, Direction, Version),
                          ejabberd_router:route(Sender, Dest, Acc, New)
                  end, Targets).

build_forward_packet(Acc, JID, Packet, Sender, Dest, Direction, Version) ->
    % The wrapping message SHOULD maintain the same 'type' attribute value;
    Type = exml_query:attr(Packet, <<"type">>, <<"normal">>),
    #xmlel{name = <<"message">>,
           attrs = [{<<"xmlns">>, <<"jabber:client">>},
                    {<<"type">>, Type},
                    {<<"from">>, jid:to_binary(Sender)},
                    {<<"to">>, jid:to_binary(Dest)}],
           children = carbon_copy_children(Acc, Version, JID, Packet, Direction)}.

carbon_copy_children(Acc, ?NS_CC_1, JID, Packet, Direction) ->
    [ #xmlel{name = atom_to_binary(Direction, utf8),
             attrs = [{<<"xmlns">>, ?NS_CC_1}]},
      #xmlel{name = <<"forwarded">>,
             attrs = [{<<"xmlns">>, ?NS_FORWARD}],
             children = [complete_packet(Acc, JID, Packet, Direction)]} ];
carbon_copy_children(Acc, ?NS_CC_2, JID, Packet, Direction) ->
    [ #xmlel{name = atom_to_binary(Direction, utf8),
             attrs = [{<<"xmlns">>, ?NS_CC_2}],
             children = [ #xmlel{name = <<"forwarded">>,
                                 attrs = [{<<"xmlns">>, ?NS_FORWARD}],
                                 children = [complete_packet(Acc, JID, Packet, Direction)]} ]} ].

enable(JID, CC) ->
    ?LOG_INFO(#{what => cc_enable,
                user => JID#jid.luser, server => JID#jid.lserver}),
    case ejabberd_sm:store_info(JID, ?CC_KEY, cc_ver_to_int(CC)) of
        {ok, ?CC_KEY} -> ok;
        {error, _} = Err -> Err
    end.

disable(JID) ->
    ?LOG_INFO(#{what => cc_disable,
                user => JID#jid.luser, server => JID#jid.lserver}),
    case ejabberd_sm:remove_info(JID, ?CC_KEY) of
        ok -> ok;
        {error, offline} -> ok
    end.

complete_packet(Acc, From, #xmlel{name = <<"message">>, attrs = OrigAttrs} = Packet, sent) ->
    %% if this is a packet sent by user on this host, then Packet doesn't
    %% include the 'from' attribute. We must add it.
    Attrs = lists:keystore(<<"xmlns">>, 1, OrigAttrs, {<<"xmlns">>, <<"jabber:client">>}),
    Packet2 = set_stanza_id(Acc, From, Packet),
    case proplists:get_value(<<"from">>, Attrs) of
        undefined ->
            Packet2#xmlel{attrs = [{<<"from">>, jid:to_binary(From)} | Attrs]};
        _ ->
            Packet2#xmlel{attrs = Attrs}
    end;

complete_packet(_Acc, _From, #xmlel{name = <<"message">>, attrs = OrigAttrs} = Packet, received) ->
    Attrs = lists:keystore(<<"xmlns">>, 1, OrigAttrs, {<<"xmlns">>, <<"jabber:client">>}),
    Packet#xmlel{attrs = Attrs}.

get_cc_enabled_resources(JID) ->
    AllSessions = ejabberd_sm:get_raw_sessions(JID),
    CCs = filter_cc_enabled_resources(AllSessions),
    Prios = filter_priority_resources(AllSessions),
    {Prios, CCs}.

filter_cc_enabled_resources(AllSessions) ->
    lists:filtermap(fun fun_filter_cc_enabled_resource/1, AllSessions).

fun_filter_cc_enabled_resource(Session = #session{usr = {_, _, R}}) ->
    case mongoose_session:get_info(Session, ?CC_KEY, undefined) of
        {?CC_KEY, V} when is_integer(V) ->
            {true, {cc_ver_from_int(V), R}};
        _ ->
            false
    end.

filter_priority_resources(AllSessions) ->
    lists:filtermap(fun fun_filter_priority_resources/1, AllSessions).

fun_filter_priority_resources(#session{usr = {_, _, R}, priority = P})
  when is_integer(P) ->
    {true, {P, R}};
fun_filter_priority_resources(_) ->
    false.

cc_ver_to_int(?NS_CC_1) -> 1;
cc_ver_to_int(?NS_CC_2) -> 2.

cc_ver_from_int(1) -> ?NS_CC_1;
cc_ver_from_int(2) -> ?NS_CC_2.

%% Servers SHOULD include the element as a child
%% of the forwarded message when using Message Carbons (XEP-0280)
%% https://xmpp.org/extensions/xep-0313.html#archives_id
set_stanza_id(Acc, From, Packet) ->
    MamId = mongoose_acc:get(mam, mam_id, undefined, Acc),
    set_stanza_id(MamId, From, Acc, Packet).

set_stanza_id(undefined, _From, _Acc, Packet) ->
    Packet;
set_stanza_id(MamId, From, _Acc, Packet) ->
    By = jid:to_bare_binary(From),
    mod_mam_utils:replace_arcid_elem(<<"stanza-id">>, By, MamId, Packet).
