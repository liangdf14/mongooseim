-module(graphql_account_SUITE).

-include_lib("eunit/include/eunit.hrl").

-compile([export_all, nowarn_export_all]).

-import(distributed_helper, [mim/0, require_rpc_nodes/1, rpc/4]).
-import(graphql_helper, [execute_command/4, execute_user_command/5, get_listener_port/1,
                         get_listener_config/1, get_ok_value/2, get_err_msg/1,
                         execute_domain_admin_command/4, get_unauthorized/1]).

-define(NOT_EXISTING_JID, <<"unknown987@unknown">>).

suite() ->
    require_rpc_nodes([mim]) ++ escalus:suite().

all() ->
    [{group, user_account},
     {group, admin_account_http},
     {group, admin_account_cli},
     {group, domain_admin_account}].

groups() ->
    [{user_account, [parallel], user_account_tests()},
     {admin_account_http, [], admin_account_tests()},
     {admin_account_cli, [], admin_account_tests()},
     {domain_admin_account, [], domain_admin_tests()}].

user_account_tests() ->
    [user_unregister,
     user_change_password].

admin_account_tests() ->
    [admin_list_users,
     admin_list_users_unknown_domain,
     admin_count_users,
     admin_count_users_unknown_domain,
     admin_check_password,
     admin_check_password_non_exisiting_user,
     admin_check_password_hash,
     admin_check_password_hash_non_existing_user,
     admin_check_plain_password_hash,
     admin_check_user,
     admin_check_non_existing_user,
     admin_register_user,
     admin_register_random_user,
     admin_remove_non_existing_user,
     admin_remove_existing_user,
     admin_ban_user,
     admin_change_user_password].

domain_admin_tests() ->
    [admin_list_users,
     domain_admin_list_users_no_permission,
     admin_count_users,
     domain_admin_count_users_no_permission,
     admin_check_password,
     domain_admin_check_password_no_permission,
     admin_check_password_hash,
     domain_admin_check_password_hash_no_permission,
     domain_admin_check_plain_password_hash_no_permission,
     admin_check_user,
     domain_admin_check_user_no_permission,
     admin_register_user,
     domain_admin_register_user_no_permission,
     admin_register_random_user,
     domain_admin_register_random_user_no_permission,
     admin_remove_existing_user,
     domain_admin_remove_user_no_permission,
     admin_ban_user,
     domain_admin_ban_user_no_permission,
     admin_change_user_password,
     domain_admin_change_user_password_no_permission].

init_per_suite(Config) ->
    Config1 = [{ctl_auth_mods, mongoose_helper:auth_modules()} | Config],
    Config2 = escalus:init_per_suite(Config1),
    Config3 = ejabberd_node_utils:init(mim(), Config2),
    dynamic_modules:save_modules(domain_helper:host_type(), Config3).

end_per_suite(Config) ->
    dynamic_modules:restore_modules(Config),
    escalus:end_per_suite(Config).

init_per_group(admin_account_http, Config) ->
    graphql_helper:init_admin_handler(init_users(Config));
init_per_group(admin_account_cli, Config) ->
    graphql_helper:init_admin_cli(init_users(Config));
init_per_group(domain_admin_account, Config) ->
    graphql_helper:init_domain_admin_handler(domain_admin_init_users(Config));
init_per_group(user_account, Config) ->
    graphql_helper:init_user(Config).

end_per_group(user_account, _Config) ->
    graphql_helper:clean(),
    escalus_fresh:clean();
end_per_group(domain_admin_account, Config) ->
    graphql_helper:clean(),
    domain_admin_clean_users(Config);
end_per_group(_GroupName, Config) ->
    graphql_helper:clean(),
    clean_users(Config).

init_users(Config) ->
    escalus:create_users(Config, escalus:get_users([alice])).

domain_admin_init_users(Config) ->
    escalus:create_users(Config, escalus:get_users([alice, alice_bis])).

clean_users(Config) ->
    escalus_fresh:clean(),
    escalus:delete_users(Config, escalus:get_users([alice])).

domain_admin_clean_users(Config) ->
    escalus_fresh:clean(),
    escalus:delete_users(Config, escalus:get_users([alice, alice_bis])).

init_per_testcase(admin_register_user = C, Config) ->
    Config1 = [{user, {<<"gql_admin_registration_test">>, domain_helper:domain()}} | Config],
    escalus:init_per_testcase(C, Config1);
init_per_testcase(admin_check_plain_password_hash = C, Config) ->
    {_, AuthMods} = lists:keyfind(ctl_auth_mods, 1, Config),
    case lists:member(ejabberd_auth_ldap, AuthMods) of
        true ->
            {skip, not_fully_supported_with_ldap};
        false ->
            AuthOpts = mongoose_helper:auth_opts_with_password_format(plain),
            Config1 = mongoose_helper:backup_and_set_config_option(
                        Config, {auth, domain_helper:host_type()}, AuthOpts),
            Config2 = escalus:create_users(Config1, escalus:get_users([carol])),
            escalus:init_per_testcase(C, Config2)
    end;
init_per_testcase(domain_admin_check_plain_password_hash_no_permission = C, Config) ->
    {_, AuthMods} = lists:keyfind(ctl_auth_mods, 1, Config),
    case lists:member(ejabberd_auth_ldap, AuthMods) of
        true ->
            {skip, not_fully_supported_with_ldap};
        false ->
            AuthOpts = mongoose_helper:auth_opts_with_password_format(plain),
            Config1 = mongoose_helper:backup_and_set_config_option(
                        Config, {auth, domain_helper:host_type()}, AuthOpts),
            Config2 = escalus:create_users(Config1, escalus:get_users([alice_bis])),
            escalus:init_per_testcase(C, Config2)
    end;
init_per_testcase(domain_admin_register_user = C, Config) ->
    Config1 = [{user, {<<"gql_domain_admin_registration_test">>, domain_helper:domain()}} | Config],
    escalus:init_per_testcase(C, Config1);
init_per_testcase(CaseName, Config) ->
    escalus:init_per_testcase(CaseName, Config).

end_per_testcase(admin_register_user = C, Config) ->
    {Username, Domain} = proplists:get_value(user, Config),
    rpc(mim(), mongoose_account_api, unregister_user, [Username, Domain]),
    escalus:end_per_testcase(C, Config);
end_per_testcase(admin_check_plain_password_hash, Config) ->
    mongoose_helper:restore_config(Config),
    escalus:delete_users(Config, escalus:get_users([carol]));
end_per_testcase(domain_admin_check_plain_password_hash_no_permission, Config) ->
    mongoose_helper:restore_config(Config),
    escalus:delete_users(Config, escalus:get_users([carol, alice_bis]));
end_per_testcase(domain_admin_register_user = C, Config) ->
    {Username, Domain} = proplists:get_value(user, Config),
    rpc(mim(), mongoose_account_api, unregister_user, [Username, Domain]),
    escalus:end_per_testcase(C, Config);
end_per_testcase(CaseName, Config) ->
    escalus:end_per_testcase(CaseName, Config).

user_unregister(Config) ->
    escalus:fresh_story_with_config(Config, [{alice, 1}], fun user_unregister_story/2).

user_unregister_story(Config, Alice) ->
    Resp = user_unregister(Alice, Config),
    Path = [data, account, unregister],
    ?assertNotEqual(nomatch, binary:match(get_ok_value(Path, Resp), <<"successfully unregistered">>)),
    % Ensure the user is removed
    AllUsers = rpc(mim(), mongoose_account_api, list_users, [domain_helper:domain()]),
    LAliceJID = jid:to_binary(jid:from_binary(escalus_client:short_jid(Alice))),
    ?assertNot(lists:member(LAliceJID, AllUsers)).

user_change_password(Config) ->
    escalus:fresh_story_with_config(Config, [{alice, 1}], fun user_change_password_story/2).

user_change_password_story(Config, Alice) ->
    % Set an empty password
    Resp1 = user_change_password(Alice, <<>>, Config),
    ?assertNotEqual(nomatch, binary:match(get_err_msg(Resp1), <<"Empty password">>)),
    % Set a correct password
    Resp2 = user_change_password(Alice, <<"kaczka">>, Config),
    Path = [data, account, changePassword],
    ?assertNotEqual(nomatch, binary:match(get_ok_value(Path, Resp2), <<"Password changed">>)).

admin_list_users(Config) ->
    Domain = domain_helper:domain(),
    Username = jid:nameprep(escalus_users:get_username(Config, alice)),
    JID = <<Username/binary, "@", Domain/binary>>,
    Resp2 = list_users(Domain, Config),
    Users = get_ok_value([data, account, listUsers], Resp2),
    ?assert(lists:member(JID, Users)).

admin_list_users_unknown_domain(Config) ->
    Resp = list_users(<<"unknown-domain">>, Config),
    ?assertEqual([], get_ok_value([data, account, listUsers], Resp)).

admin_count_users(Config) ->
    % A domain with at least one user
    Domain = domain_helper:domain(),
    Resp2 = count_users(Domain, Config),
    ?assert(0 < get_ok_value([data, account, countUsers], Resp2)).

admin_count_users_unknown_domain(Config) ->
    Resp = count_users(<<"unknown-domain">>, Config),
    ?assertEqual(0, get_ok_value([data, account, countUsers], Resp)).

admin_check_password(Config) ->
    Password = lists:last(escalus_users:get_usp(Config, alice)),
    BinJID = escalus_users:get_jid(Config, alice),
    Path = [data, account, checkPassword],
    % A correct password
    Resp1 = check_password(BinJID, Password, Config),
    ?assertMatch(#{<<"correct">> := true, <<"message">> := _}, get_ok_value(Path, Resp1)),
    % An incorrect password
    Resp2 = check_password(BinJID, <<"incorrect_pw">>, Config),
    ?assertMatch(#{<<"correct">> := false, <<"message">> := _}, get_ok_value(Path, Resp2)).

admin_check_password_non_exisiting_user(Config) ->
    Password = lists:last(escalus_users:get_usp(Config, alice)),
    Resp = check_password(?NOT_EXISTING_JID, Password, Config),
    ?assertNotEqual(nomatch, binary:match(get_err_msg(Resp), <<"not exist">>)).

admin_check_password_hash(Config) ->
    UserSCRAM = escalus_users:get_jid(Config, alice),
    EmptyHash = list_to_binary(get_md5(<<>>)),
    Method = <<"md5">>,
    % SCRAM password user
    Resp1 = check_password_hash(UserSCRAM, EmptyHash, Method, Config),
    ?assertNotEqual(nomatch, binary:match(get_err_msg(Resp1), <<"SCRAM password">>)).

admin_check_password_hash_non_existing_user(Config) ->
    EmptyHash = list_to_binary(get_md5(<<>>)),
    Method = <<"md5">>,
    Resp2 = check_password_hash(?NOT_EXISTING_JID, EmptyHash, Method, Config),
    ?assertNotEqual(nomatch, binary:match(get_err_msg(Resp2), <<"not exist">>)).

admin_check_plain_password_hash(Config) ->
    UserJID = escalus_users:get_jid(Config, carol),
    Password = lists:last(escalus_users:get_usp(Config, carol)),
    Method = <<"md5">>,
    Hash = list_to_binary(get_md5(Password)),
    WrongHash = list_to_binary(get_md5(<<"wrong password">>)),
    Path = [data, account, checkPasswordHash],
    % A correct hash
    Resp = check_password_hash(UserJID, Hash, Method, Config),
    ?assertMatch(#{<<"correct">> := true, <<"message">> := _}, get_ok_value(Path, Resp)),
    % An incorrect hash
    Resp2 = check_password_hash(UserJID, WrongHash, Method, Config),
    ?assertMatch(#{<<"correct">> := false, <<"message">> := _}, get_ok_value(Path, Resp2)),
    % A not-supported hash method
    Resp3 = check_password_hash(UserJID, Hash, <<"a">>, Config),
    ?assertNotEqual(nomatch, binary:match(get_err_msg(Resp3), <<"not supported">>)).

admin_check_user(Config) ->
    BinJID = escalus_users:get_jid(Config, alice),
    Path = [data, account, checkUser],
    Resp = check_user(BinJID, Config),
    ?assertMatch(#{<<"exist">> := true, <<"message">> := _}, get_ok_value(Path, Resp)).

admin_check_non_existing_user(Config) ->
    Path = [data, account, checkUser],
    Resp = check_user(?NOT_EXISTING_JID, Config),
    ?assertMatch(#{<<"exist">> := false, <<"message">> := _}, get_ok_value(Path, Resp)).

admin_register_user(Config) ->
    Password = <<"my_password">>,
    {Username, Domain} = proplists:get_value(user, Config),
    Path = [data, account, registerUser, message],
    % Register a new user
    Resp1 = register_user(Domain, Username, Password, Config),
    ?assertNotEqual(nomatch, binary:match(get_ok_value(Path, Resp1), <<"successfully registered">>)),
    % Try to register a user with existing name
    Resp2 = register_user(Domain, Username, Password, Config),
    ?assertNotEqual(nomatch, binary:match(get_err_msg(Resp2), <<"already registered">>)).

admin_register_random_user(Config) ->
    Password = <<"my_password">>,
    Domain = domain_helper:domain(),
    Path = [data, account, registerUser],
    % Register a new user
    Resp1 = register_random_user(Domain, Password, Config),
    #{<<"message">> := Msg, <<"jid">> := JID} = get_ok_value(Path, Resp1),
    {Username, Server} = jid:to_lus(jid:from_binary(JID)),

    ?assertNotEqual(nomatch, binary:match(Msg, <<"successfully registered">>)),
    {ok, _} = rpc(mim(), mongoose_account_api, unregister_user, [Username, Server]).

admin_remove_non_existing_user(Config) ->
    Resp = remove_user(?NOT_EXISTING_JID, Config),
    ?assertNotEqual(nomatch, binary:match(get_err_msg(Resp), <<"not exist">>)).

admin_remove_existing_user(Config) ->
    escalus:fresh_story(Config, [{alice, 1}], fun(Alice) ->
        Path = [data, account, removeUser, message],
        BinJID = escalus_client:full_jid(Alice),
        Resp4 = remove_user(BinJID, Config),
        ?assertNotEqual(nomatch, binary:match(get_ok_value(Path, Resp4),
                                              <<"successfully unregister">>))
    end).

admin_ban_user(Config) ->
    Path = [data, account, banUser, message],
    Reason = <<"annoying">>,
    % Ban an existing user
    escalus:fresh_story(Config, [{alice, 1}], fun(Alice) ->
        BinJID = escalus_client:full_jid(Alice),
        Resp1 = ban_user(BinJID, Reason, Config),
        ?assertNotEqual(nomatch, binary:match(get_ok_value(Path, Resp1), <<"successfully banned">>))
    end).

admin_ban_non_existing_user(Config) ->
    Reason = <<"annoying">>,
    Resp = ban_user(?NOT_EXISTING_JID, Reason, Config),
    ?assertNotEqual(nomatch, binary:match(get_err_msg(Resp), <<"not allowed">>)).

admin_change_user_password(Config) ->
    Path = [data, account, changeUserPassword, message],
    NewPassword = <<"new password">>,
    escalus:fresh_story(Config, [{alice, 1}], fun(Alice) ->
        BinJID = escalus_client:full_jid(Alice),
        % Set an empty password
        Resp1 = change_user_password(BinJID, <<>>, Config),
        ?assertNotEqual(nomatch, binary:match(get_err_msg(Resp1), <<"Empty password">>)),
        % Set non-empty password
        Resp2 = change_user_password(BinJID, NewPassword, Config),
        ?assertNotEqual(nomatch, binary:match(get_ok_value(Path, Resp2), <<"Password changed">>))
    end).

admin_change_non_exisisting_user_password(Config) ->
    NewPassword = <<"new password">>,
    Resp = change_user_password(?NOT_EXISTING_JID, NewPassword, Config),
    ?assertNotEqual(nomatch, binary:match(get_err_msg(Resp), <<"not allowed">>)).

domain_admin_list_users_no_permission(Config) ->
    % An unknown domain
    Resp1 = list_users(<<"unknown-domain">>, Config),
    get_unauthorized(Resp1),
    % An external domain
    Resp2 = list_users(domain_helper:secondary_domain(), Config),
    get_unauthorized(Resp2).

domain_admin_count_users_no_permission(Config) ->
    % An unknown domain
    Resp1 = count_users(<<"unknown-domain">>, Config),
    get_unauthorized(Resp1),
    % An external domain
    Resp2 = count_users(domain_helper:secondary_domain(), Config),
    get_unauthorized(Resp2).

domain_admin_check_password_no_permission(Config) ->
    Password = lists:last(escalus_users:get_usp(Config, alice)),
    PasswordOutside = lists:last(escalus_users:get_usp(Config, alice_bis)),
    BinOutsideJID = escalus_users:get_jid(Config, alice_bis),
    % An external domain user
    Resp3 = check_password(BinOutsideJID, PasswordOutside, Config),
    get_unauthorized(Resp3),
    % A non-existing user
    Resp4 = check_password(?NOT_EXISTING_JID, Password, Config),
    get_unauthorized(Resp4).

domain_admin_check_password_hash_no_permission(Config) ->
    ExternalUserSCRAM = escalus_users:get_jid(Config, alice_bis),
    EmptyHash = list_to_binary(get_md5(<<>>)),
    Method = <<"md5">>,
    % An external domain user
    Resp1 = check_password_hash(ExternalUserSCRAM, EmptyHash, Method, Config),
    get_unauthorized(Resp1),
    % A non-existing user
    Resp2 = check_password_hash(?NOT_EXISTING_JID, EmptyHash, Method, Config),
    get_unauthorized(Resp2).

domain_admin_check_plain_password_hash_no_permission(Config) ->
    Method = <<"md5">>,
    ExternalUserJID = escalus_users:get_jid(Config, alice_bis),
    ExternalPassword = lists:last(escalus_users:get_usp(Config, alice_bis)),
    ExternalHash = list_to_binary(get_md5(ExternalPassword)),
    get_unauthorized(check_password_hash(ExternalUserJID, ExternalHash, Method, Config)).

domain_admin_check_user_no_permission(Config) ->
    ExternalBinJID = escalus_users:get_jid(Config, alice_bis),
    % An external domain user
    Resp1 = check_user(ExternalBinJID, Config),
    get_unauthorized(Resp1),
    % A non-existing user
    Resp2 = check_user(?NOT_EXISTING_JID, Config),
    get_unauthorized(Resp2).

domain_admin_register_user_no_permission(Config) ->
    Password = <<"my_password">>,
    Domain = <<"unknown-domain">>,
    get_unauthorized(register_user(Domain, external_user, Password, Config)).

domain_admin_register_random_user_no_permission(Config) ->
    Password = <<"my_password">>,
    Domain = domain_helper:secondary_domain(),
    Resp = register_random_user(Domain, Password, Config),
    get_unauthorized(Resp).

domain_admin_remove_user_no_permission(Config) ->
    get_unauthorized(remove_user(?NOT_EXISTING_JID, Config)),
    escalus:fresh_story(Config, [{alice_bis, 1}], fun(AliceBis) ->
        BinJID = escalus_client:full_jid(AliceBis),
        get_unauthorized(remove_user(BinJID, Config))
    end).

domain_admin_ban_user_no_permission(Config) ->
    Reason = <<"annoying">>,
    % Ban not existing user
    Resp1 = ban_user(?NOT_EXISTING_JID, Reason, Config),
    get_unauthorized(Resp1),
    % Ban an external domain user
    escalus:fresh_story(Config, [{alice_bis, 1}], fun(AliceBis) ->
        BinJID = escalus_client:full_jid(AliceBis),
        Resp2 = ban_user(BinJID, Reason, Config),
        get_unauthorized(Resp2)
    end).

domain_admin_change_user_password_no_permission(Config) ->
    NewPassword = <<"new password">>,
    % Change password of not existing user
    Resp1 = change_user_password(?NOT_EXISTING_JID, NewPassword, Config),
    get_unauthorized(Resp1),
    % Change external domain user password
    escalus:fresh_story(Config, [{alice_bis, 1}], fun(AliceBis) ->
        BinJID = escalus_client:full_jid(AliceBis),
        Resp2 = change_user_password(BinJID, NewPassword, Config),
        get_unauthorized(Resp2)
    end).

%% Helpers

get_md5(AccountPass) ->
    lists:flatten([io_lib:format("~.16B", [X])
                   || X <- binary_to_list(crypto:hash(md5, AccountPass))]).

%% Commands

user_unregister(User, Config) ->
    execute_user_command(<<"account">>, <<"unregister">>, User, #{}, Config).

user_change_password(User, Password, Config) ->
    Vars = #{<<"newPassword">> => Password},
    execute_user_command(<<"account">>, <<"changePassword">>, User, Vars, Config).

list_users(Domain, Config) ->
    Vars = #{<<"domain">> => Domain},
    execute_command(<<"account">>, <<"listUsers">>, Vars, Config).

count_users(Domain, Config) ->
    Vars = #{<<"domain">> => Domain},
    execute_command(<<"account">>, <<"countUsers">>, Vars, Config).

check_password(User, Password, Config) ->
    Vars = #{<<"user">> => User, <<"password">> => Password},
    execute_command(<<"account">>, <<"checkPassword">>, Vars, Config).

check_password_hash(User, PasswordHash, HashMethod, Config) ->
    Vars = #{<<"user">> => User, <<"passwordHash">> => PasswordHash, <<"hashMethod">> => HashMethod},
    execute_command(<<"account">>, <<"checkPasswordHash">>, Vars, Config).

check_user(User, Config) ->
    Vars = #{<<"user">> => User},
    execute_command(<<"account">>, <<"checkUser">>, Vars, Config).

register_user(Domain, Username, Password, Config) ->
    Vars = #{<<"domain">> => Domain, <<"username">> => Username, <<"password">> => Password},
    execute_command(<<"account">>, <<"registerUser">>, Vars, Config).

register_random_user(Domain, Password, Config) ->
    Vars = #{<<"domain">> => Domain, <<"password">> => Password},
    execute_command(<<"account">>, <<"registerUser">>, Vars, Config).

remove_user(User, Config) ->
    Vars = #{<<"user">> => User},
    execute_command(<<"account">>, <<"removeUser">>, Vars, Config).

ban_user(JID, Reason, Config) ->
    Vars = #{<<"user">> => JID, <<"reason">> => Reason},
    execute_command(<<"account">>, <<"banUser">>, Vars, Config).

change_user_password(JID, NewPassword, Config) ->
    Vars = #{<<"user">> => JID, <<"newPassword">> => NewPassword},
    execute_command(<<"account">>, <<"changeUserPassword">>, Vars, Config).
