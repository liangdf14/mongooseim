-module(mongoose_client_api_rooms_config).

-behaviour(mongoose_client_api).
-export([routes/0]).

-behaviour(cowboy_rest).
-export([trails/0]).
-export([init/2]).
-export([content_types_provided/2]).
-export([content_types_accepted/2]).
-export([is_authorized/2]).
-export([allowed_methods/2]).
-export([resource_exists/2]).

-export([from_json/2]).

-ignore_xref([from_json/2, trails/0]).

-spec routes() -> mongoose_http_handler:routes().
routes() ->
    [{"/rooms/[:id]/config", ?MODULE, #{}}].

trails() ->
    mongoose_client_api_rooms_config_doc:trails().

init(Req, Opts) ->
    mongoose_client_api:init(Req, Opts).

is_authorized(Req, State) ->
    mongoose_client_api:is_authorized(Req, State).

content_types_provided(Req, State) ->
    mongoose_client_api_rooms:content_types_provided(Req, State).

content_types_accepted(Req, State) ->
    mongoose_client_api_rooms:content_types_accepted(Req, State).

allowed_methods(Req, State) ->
    {[<<"OPTIONS">>, <<"PUT">>], Req, State}.

resource_exists(Req, State) ->
    mongoose_client_api_rooms:resource_exists(Req, State).

from_json(Req, State = #{was_replied := true}) ->
    {true, Req, State};
from_json(Req, State) ->
    Method = cowboy_req:method(Req),
    {ok, Body, Req2} = cowboy_req:read_body(Req),
    case mongoose_client_api:json_to_map(Body) of
        {ok, #{<<"name">> := N, <<"subject">> := S} = JSONData} when is_binary(N), is_binary(S) ->
            handle_request(Method, JSONData, Req2, State);
        _ ->
            {false, Req, State}
    end.

handle_request(Method, JSONData, Req, State) ->
    case handle_request_by_method(Method, JSONData, Req, State) of
        {ok, _} ->
            {true, Req, State};
        {not_allowed, _} ->
            mongoose_client_api:forbidden_request(Req, State);
        {_, _} ->
            {false, Req, State}
    end.

handle_request_by_method(<<"PUT">>,
                         #{<<"name">> := RoomName, <<"subject">> := Subject},
                         Req, State) ->
    mongoose_client_api_rooms:assert_room_id_set(Req, State),
    #{jid := UserJID, room := #{jid := RoomJID}} = State,
    Config = #{<<"roomname">> => RoomName, <<"subject">> => Subject},
    mod_muc_light_api:change_room_config(RoomJID, UserJID, Config).
