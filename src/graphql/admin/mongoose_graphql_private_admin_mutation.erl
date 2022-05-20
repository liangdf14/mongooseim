-module(mongoose_graphql_private_admin_mutation).
-behaviour(mongoose_graphql).

-export([execute/4]).

-ignore_xref([execute/4]).

-include("../mongoose_graphql_types.hrl").

-import(mongoose_graphql_helper, [make_error/2, format_result/2]).

execute(_Ctx, _Obj, <<"setPrivate">>, #{<<"user">> := CallerJID,
        <<"privateString">> := Element}) ->
    case mod_private_api:private_set(CallerJID, Element) of
        {ok, _} = Result -> Result;
        Error ->
            make_error(Error, #{user => CallerJID, element => Element})
    end.
