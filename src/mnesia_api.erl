-module(mnesia_api).

-export([set_master/1,
         backup_mnesia/1, restore_mnesia/1,
         dump_mnesia/1, dump_table/2, load_mnesia/1,
         install_fallback_mnesia/1,
         mnesia_change_nodename/4,
         restore/1, mnesia_info/1]).

-type info_result() :: #{binary() => binary() | [binary()] | integer()}.
-type info_error() :: {{internal_server_error | bad_key_error, binary()}, #{key => binary()}}.
-type dump_error() :: table_does_not_exist | file_error | cannot_dump.

-spec mnesia_info(Keys::[binary()]) -> [info_result() | info_error()].
mnesia_info(null) ->
    Value = mnesia:system_info(all),
    lists:foldl(fun({Key, Result}, AllAcc) ->
        AllAcc ++ [{ok, #{<<"result">> => convert_value(Result), <<"key">> => Key}}]
    end, [], Value);
mnesia_info(Keys) ->
    lists:foldl(fun
        (<<"all">>, Acc) ->
            Acc ++ [{{bad_key_error, <<"Key \"all\" does not exist">>},
                    #{key => <<"all">>}}];
        (Key, Acc) ->
            try mnesia:system_info(binary_to_atom(Key)) of
                Value ->
                    Acc ++ [{ok, #{<<"result">> => convert_value(Value), <<"key">> => Key}}]
            catch
                _:{_, {badarg, _}} ->
                    Acc ++ [{{bad_key_error, <<"Key \"", Key/binary, "\" does not exist">>},
                            #{key => Key}}];
                _:_ ->
                    Acc ++ [{{internal_server_error, <<"Internal server error">>}, #{key => Key}}]
            end
    end, [], Keys).

-spec dump_mnesia(file:name()) -> {error, {dump_error(), io_lib:chars()}} | {ok, []}.
dump_mnesia(Path) ->
    Tabs = get_local_tables(),
    dump_tables(Path, Tabs).

-spec dump_table(file:name(), string()) -> {error, {dump_error(), io_lib:chars()}} | {ok, []}.
dump_table(Path, STable) ->
    Table = list_to_atom(STable),
    dump_tables(Path, [Table]).

-spec backup_mnesia(file:name()) ->
    {error, {wrong_filename | cannot_backup, io_lib:chars()}} | {ok, []}.
backup_mnesia(Path) ->
    case mnesia:backup(Path) of
        ok ->
            {ok, ""};
        {error, {'EXIT', {error, enoent}}} ->
            {error, {wrong_filename, io_lib:format("Wrong filename: ~p", [Path])}};
        {error, Reason} ->
            String = io_lib:format("Can't store backup in ~p at node ~p: ~p",
                                   [filename:absname(Path), node(), Reason]),
            {error, {cannot_backup, String}}
    end.

-spec restore_mnesia(file:name()) -> {error, {cannot_restore, io_lib:chars()}}
                                   | {error, {file_not_found, io_lib:chars()}}
                                   | {error, {not_a_log_file_error, io_lib:chars()}}
                                   | {ok, []}
                                   | {error, {table_does_not_exist, io_lib:chars()}}.
restore_mnesia(Path) ->
    ErrorString=lists:flatten( io_lib:format("Can't restore backup from ~p at node ~p: ",
                                             [filename:absname(Path), node()])),
    case mnesia_api:restore(Path) of
        {atomic, _} ->
            {ok, ""};
        {aborted, {no_exists, Table}} ->
            String = io_lib:format("~sTable ~p does not exist.", [ErrorString, Table]),
            {error, {table_does_not_exist, String}};
        {aborted, enoent} ->
            String = ErrorString ++ "File not found.",
            {error, {file_not_found, String}};
        {aborted, {not_a_log_file, Filename}} ->
            String = "Wrong file " ++ Filename ++ " structure",
            {error, {not_a_log_file_error, String}};
        {aborted, Reason} ->
            String = io_lib:format("~s~p", [ErrorString, Reason]),
            {error, {cannot_restore, String}}
    end.

-spec load_mnesia(file:name()) ->
    {error, {cannot_load | bad_file_format | file_not_found, io_lib:chars()}} | {ok, []}.
load_mnesia(Path) ->
    case mnesia:load_textfile(Path) of
        {atomic, ok} ->
            {ok, ""};
        {error, bad_header} ->
            {error, {bad_file_format, "File has wrong format"}};
        {error, read} ->
            {error, {bad_file_format, "File has wrong format"}};
        {error, open} ->
            {error, {file_not_found, "File was not found"}};
        {error, Reason} ->
            String = io_lib:format("Can't load dump in ~p at node ~p: ~p",
                                   [filename:absname(Path), node(), Reason]),
            {error, {cannot_load, String}}
    end.

-spec mnesia_change_nodename(string(), string(), _, _) -> {ok, _} | {error, _}.
mnesia_change_nodename(FromString, ToString, Source, Target) ->
    From = list_to_atom(FromString),
    To = list_to_atom(ToString),
    Switch =
        fun
            (Node) when Node == From ->
                io:format("     - Replacing nodename: '~p' with: '~p'~n", [From, To]),
                To;
            (Node) when Node == To ->
                %% throw({error, already_exists});
                io:format("     - Node: '~p' will not be modified (it is already '~p')~n", [Node, To]),
                Node;
            (Node) ->
                io:format("     - Node: '~p' will not be modified (it is not '~p')~n", [Node, From]),
                Node
        end,
    Convert =
        fun
            ({schema, db_nodes, Nodes}, Acc) ->
                io:format(" +++ db_nodes ~p~n", [Nodes]),
                {[{schema, db_nodes, lists:map(Switch, Nodes)}], Acc};
            ({schema, version, Version}, Acc) ->
                io:format(" +++ version: ~p~n", [Version]),
                {[{schema, version, Version}], Acc};
            ({schema, cookie, Cookie}, Acc) ->
                io:format(" +++ cookie: ~p~n", [Cookie]),
                {[{schema, cookie, Cookie}], Acc};
            ({schema, Tab, CreateList}, Acc) ->
                io:format("~n * Checking table: '~p'~n", [Tab]),
                Keys = [ram_copies, disc_copies, disc_only_copies],
                OptSwitch =
                    fun({Key, Val}) ->
                            case lists:member(Key, Keys) of
                                true ->
                                    io:format("   + Checking key: '~p'~n", [Key]),
                                    {Key, lists:map(Switch, Val)};
                                false -> {Key, Val}
                            end
                    end,
                Res = {[{schema, Tab, lists:map(OptSwitch, CreateList)}], Acc},
                Res;
            (Other, Acc) ->
                {[Other], Acc}
        end,
    case mnesia:traverse_backup(Source, Target, Convert, switched) of
        {ok, _} = Result -> Result;
        {error, Reason} ->
            String = io_lib:format("Error while changing node's name ~p:~n~p",
                                   [node(), Reason]),
            case Reason of
                {_, enoent} ->
                    {error, {file_not_found, String}};
                {_, {not_a_log_file, _}} ->
                    {error, {bad_file_format, String}};
                _ ->
                    {error, {error, String}}
            end
    end.

-spec install_fallback_mnesia(file:name()) ->
                        {cannot_fallback, io_lib:chars()} | {ok, []}.
install_fallback_mnesia(Path) ->
    case mnesia:install_fallback(Path) of
        ok ->
            {ok, ""};
        {error, Reason} ->
            String = io_lib:format("Can't install fallback from ~p at node ~p: ~p",
                                   [filename:absname(Path), node(), Reason]),
            {cannot_fallback, String}
    end.

-spec set_master(Node :: atom() | string()) -> {error, io_lib:chars()} | {ok, []}.
set_master("self") ->
    set_master(node());
set_master(NodeString) when is_list(NodeString) ->
    set_master(list_to_atom(NodeString));
set_master(Node) when is_atom(Node) ->
    case mnesia:set_master_nodes([Node]) of
        ok ->
            {ok, ""};
        {error, Reason} ->
            String = io_lib:format("Can't set master node ~p at node ~p:~n~p",
                                   [Node, node(), Reason]),
            {error, String}
    end.

%---------------------------------------------------------------------------------------------------
%                                              Helpers
%---------------------------------------------------------------------------------------------------

-spec convert_value(any()) -> binary() | [{ok, any()}] | integer().
convert_value(Value) when is_binary(Value) ->
    Value;
convert_value(Value) when is_integer(Value) ->
    Value;
convert_value(Value) when is_atom(Value) ->
    atom_to_binary(Value);
convert_value([Head | _] = Value) when is_integer(Head) ->
    list_to_binary(Value);
convert_value(Value) when is_list(Value) ->
    [{ok, convert_value(Item)} || Item <- Value];
convert_value(Value) ->
    list_to_binary(io_lib:format("~p", [Value])).

-spec dump_tables(file:name(), list()) -> {error, {dump_error(), io_lib:chars()}} | {ok, []}.
dump_tables(File, Tabs) ->
    case dump_to_textfile(Tabs, file:open(File, [write])) of
        ok ->
            {ok, ""};
        {file_error, Reason} ->
            String = io_lib:format("Can't store dump in ~p at node ~p: ~p",
                                   [filename:absname(File), node(), Reason]),
            {error, {file_error, String}};
        {error, Reason} ->
            String = io_lib:format("Can't store dump in ~p at node ~p: ~p",
                                   [filename:absname(File), node(), Reason]),
            case Reason of
                table_does_not_exist ->
                    {error, {table_does_not_exist, String}};
                _ ->
                    {error, {cannot_dump, String}}
            end
    end.

%% @doc Mnesia database restore
restore(Path) ->
    mnesia:restore(Path, [{keep_tables, keep_tables()},
                          {default_op, skip_tables}]).

%% @doc This function returns a list of tables that should be kept from a
%% previous version backup.
%% Obsolete tables or tables created by modules which are no longer used are not
%% restored and are ignored.
-spec keep_tables() -> [atom()].
keep_tables() ->
    lists:flatten([acl, passwd, disco_publish, keep_modules_tables()]).

%% @doc Returns the list of modules tables in use, according to the list of
%% actually loaded modules
-spec keep_modules_tables() -> [[atom()]]. % list of lists
keep_modules_tables() ->
    lists:map(fun(Module) -> module_tables(Module) end,
              gen_mod:loaded_modules()).

%% TODO: This mapping should probably be moved to a callback function in each module.
%% @doc Mapping between modules and their tables
-spec module_tables(_) -> [atom()].
module_tables(mod_announce) -> [motd, motd_users];
module_tables(mod_irc) -> [irc_custom];
module_tables(mod_last) -> [last_activity];
module_tables(mod_muc) -> [muc_room, muc_registered];
module_tables(mod_offline) -> [offline_msg];
module_tables(mod_privacy) -> [privacy];
module_tables(mod_private) -> [private_storage];
module_tables(mod_pubsub) -> [pubsub_node];
module_tables(mod_roster) -> [roster];
module_tables(mod_shared_roster) -> [sr_group, sr_user];
module_tables(mod_vcard) -> [vcard, vcard_search];
module_tables(_Other) -> [].

-spec get_local_tables() -> [any()].
get_local_tables() ->
    Tabs1 = lists:delete(schema, mnesia:system_info(local_tables)),
    Tabs = lists:filter(
             fun(T) ->
                     case mnesia:table_info(T, storage_type) of
                         disc_copies -> true;
                         disc_only_copies -> true;
                         _ -> false
                     end
             end, Tabs1),
    Tabs.

-spec dump_to_textfile(any(),
                      {error, atom()} | {ok, pid() | {file_descriptor, atom() | tuple(), _}}
                      ) -> ok | {error, atom()} | {file_error, atom()}.
dump_to_textfile(Tabs, {ok, F}) ->
    case get_info_about_tables(Tabs, F) of
        ok ->
            lists:foreach(fun(T) -> dump_tab(F, T) end, Tabs),
            file:close(F);
        {error, _} = Error ->
            Error
    end;
dump_to_textfile(_, {error, Reason}) ->
    {file_error, Reason}.

-spec get_info_about_tables(any(), pid()) -> ok | {error, atom()}.
get_info_about_tables(Tabs, File) ->
    try
        Defs = lists:map(
                 fun(T) -> {T, [{record_name, mnesia:table_info(T, record_name)},
                                {attributes, mnesia:table_info(T, attributes)}]}
                 end,
                 Tabs),
        io:format(File, "~p.~n", [{tables, Defs}])
    catch _:_ ->
        {error, table_does_not_exist}
    end.

-spec dump_tab(pid(), atom()) -> ok.
dump_tab(F, T) ->
    W = mnesia:table_info(T, wild_pattern),
    {atomic, All} = mnesia:transaction(
                     fun() -> mnesia:match_object(T, W, read) end),
    lists:foreach(
      fun(Term) -> io:format(F, "~p.~n", [setelement(1, Term, T)]) end, All).
