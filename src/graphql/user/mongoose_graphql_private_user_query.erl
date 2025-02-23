-module(mongoose_graphql_private_user_query).
-behaviour(mongoose_graphql).

-export([execute/4]).

-ignore_xref([execute/4]).

-include("../mongoose_graphql_types.hrl").

-import(mongoose_graphql_helper, [make_error/2, format_result/2]).

execute(#{user := CallerJID}, _Obj, <<"getPrivate">>,
        #{<<"element">> := Element, <<"nameSpace">> := SubElement}) ->
    case mod_private_api:private_get(CallerJID, Element, SubElement) of
        {ok, _} = Result -> Result;
        Error ->
            make_error(Error, #{user => CallerJID, element => Element, subElement => SubElement})
    end.
