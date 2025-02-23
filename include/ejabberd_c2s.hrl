-include("mod_privacy.hrl").

-define(STREAM_MGMT_H_MAX, (1 bsl 32 - 1)).
-define(CONSTRAINT_CHECK_TIMEOUT, 5).  %% seconds

-type jid_set() :: gb_sets:set(jid:simple_jid()).

-type authenticated_state() :: boolean() | resumed | replaced.

-type debug_presences() :: {atom(), non_neg_integer()}.

%% pres_a contains all the presence available send (either through roster mechanism or directed).
%% Directed presence unavailable remove user from pres_a.
-record(state, {socket,
                sockmod :: ejabberd:sockmod(),
                socket_monitor,
                xml_socket,
                streamid :: undefined | binary(),
                sasl_state,
                access,
                shaper,
                zlib = {false, 0}          :: {boolean(), integer()},
                tls_enabled = false   :: boolean(),
                tls_options           :: mongoose_tls:options() | undefined,
                tls_mode              :: no_tls | tls | starttls | starttls_required,
                authenticated = false :: authenticated_state(),
                host_type             :: binary() | undefined,
                jid                   :: jid:jid() | undefined,
                user = <<>>           :: jid:user(),
                server = <<>>         :: jid:server(),
                resource = <<>>       :: jid:resource(),
                sid                   :: ejabberd_sm:sid() | undefined,
                %% We have _subscription to_ these users' presence status;
                %% i.e. they send us presence updates.
                %% This comes from the roster.
                pres_t = gb_sets:new() :: jid_set() | debug_presences(),
                %% We have _subscription from_ these users,
                %% i.e. they have subscription to us.
                %% We send them presence updates.
                %% This comes from the roster.
                pres_f = gb_sets:new() :: jid_set() | debug_presences(),
                %% We're _available_ to these users,
                %% i.e. we broadcast presence updates to them.
                %% This may change throughout the session.
                pres_a = gb_sets:new() :: jid_set() | debug_presences(),
                %% We are _invisible_ to these users.
                %% This may change throughout the session.
                pres_i = gb_sets:new() :: jid_set() | debug_presences(),
                pending_invitations = [],
                pres_last, pres_pri,
                pres_timestamp :: integer() | undefined, % unix time in seconds
                %% Are we invisible?
                pres_invis = false :: boolean(),
                privacy_list = #userlist{} :: mongoose_privacy:userlist(),
                conn = unknown,
                auth_module     :: ejabberd_auth:authmodule(),
                ip              :: {inet:ip_address(), inet:port_number()} | undefined,
                aux_fields = [] :: [{aux_key(), aux_value()}],
                lang            :: ejabberd:lang(),
                stream_mgmt = false,
                stream_mgmt_in = 0,
                stream_mgmt_id,
                stream_mgmt_out_acked = 0,
                stream_mgmt_buffer = [] :: [mongoose_acc:t()],
                stream_mgmt_buffer_size = 0,
                stream_mgmt_buffer_max,
                stream_mgmt_ack_freq,
                stream_mgmt_resume_timeout,
                stream_mgmt_resume_tref,
                stream_mgmt_resumed_from,
                stream_mgmt_constraint_check_tref,
                csi_state = active :: mod_csi:state(),
                csi_buffer = [] :: [mongoose_acc:t()],
                hibernate_after = 0 :: non_neg_integer(),
                replaced_pids = [] :: [{MonitorRef :: reference(), ReplacedPid :: pid()}],
                handlers = #{} :: #{ term() => {module(), atom(), term()} },
                cred_opts :: mongoose_credentials:opts()
                }).
-type aux_key() :: atom().
-type aux_value() :: any().
-type state() :: #state{}.

-type statename() :: atom().
-type conntype() :: 'c2s'
                  | 'c2s_compressed'
                  | 'c2s_compressed_tls'
                  | 'c2s_tls'
                  | 'http_bind'
                  | 'http_poll'
                  | 'unknown'.

%% FSM handler return value
-type fsm_return() :: {'stop', Reason :: 'normal', state()}
                    | {'next_state', statename(), state()}
                    | {'next_state', statename(), state(), Timeout :: integer()}.

-type blocking_type() :: 'block' | 'unblock'.

-type broadcast_type() :: {exit, Reason :: binary()}
                        | {item, IJID :: jid:simple_jid() | jid:jid(),
                           ISubscription :: from | to | both | none | remove}
                        | {privacy_list, PrivList :: mongoose_privacy:userlist(),
                           PrivListName :: binary()}
                        | {blocking, UserList :: mongoose_privacy:userlist(), What :: blocking_type(),
                                     [binary()]}
                        | unknown.

-type broadcast() :: {broadcast, broadcast_type() | mongoose_acc:t()}.

-type broadcast_result() :: {new_state, NewState :: state()}
                          | {exit, Reason :: binary()}
                          | {send_new, From :: jid:jid(), To :: jid:jid(),
                             Packet :: exml:element(),
                             NewState :: state()}.

-type routing_result_atom() :: allow | deny | forbidden | ignore | block | invalid | probe.

-type routing_result() :: {DoRoute :: routing_result_atom(), NewAcc :: mongoose_acc:t(),
                           NewState :: state()}
                        | {DoRoute :: routing_result_atom(), NewAcc :: mongoose_acc:t(),
                           NewPacket :: exml:element(), NewState :: state()}.

%-define(DBGFSM, true).
-ifdef(DBGFSM).
-define(FSMOPTS, [{debug, [trace]}]).
-else.
-define(FSMOPTS, []).
-endif.

%% Module start with or without supervisor:
-ifdef(NO_TRANSIENT_SUPERVISORS).
-define(SUPERVISOR_START(SockData, Opts),
        ?GEN_FSM:start(ejabberd_c2s, [SockData, Opts], ?FSMOPTS ++ fsm_limit_opts(Opts))).
-else.
-define(SUPERVISOR_START(SockData, Opts),
        supervisor:start_child(ejabberd_c2s_sup, [SockData, Opts])).
-endif.

%% This is the timeout to apply between event when starting a new
%% session:
-define(C2S_OPEN_TIMEOUT, 60000).
