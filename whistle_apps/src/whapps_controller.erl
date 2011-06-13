%%%-------------------------------------------------------------------
%%% @author James Aimonetti <james@2600hz.org>
%%% @copyright (C) 2010-2011, VoIP INC
%%% @doc
%%%
%%% @end
%%% Created :  1 Dec 2010 by James Aimonetti <james@2600hz.org>
%%%-------------------------------------------------------------------
-module(whapps_controller).

%% API
-export([start_link/0, start_app/1, set_amqp_host/1, set_couch_host/1, set_couch_host/3, stop_app/1, running_apps/0]).
-export([get_amqp_host/0, restart_app/1]).

-define(STARTUP_FILE, [code:lib_dir(whistle_apps, priv), "/startup.config"]).

-include_lib("whistle/include/wh_log.hrl").

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    preload_whapps(),
    ignore.

-spec(start_app/1 :: (App :: atom()) -> ok | exists).
start_app(App) when is_atom(App) ->
    ?LOG_SYS("attempting to start whapp ~s", [App]),
    case lists:keyfind(App, 1, supervisor:which_children(whapps_sup)) of
	{App, _, _, _} -> exists;
	false ->
	    {ok, _} = whapps_sup:start_app(App),
	    ok
    end.

-spec(stop_app/1 :: (App :: atom()) -> 'ok' | tuple('error', 'running' | 'not_found' | 'simple_one_for_one')).
stop_app(App) when is_atom(App) ->
    ?LOG_SYS("attempting to stop whapp ~s", [App]),
    whapps_sup:stop_app(App).

-spec(restart_app/1 :: (App :: atom()) -> tuple(ok, pid() | undefined) | tuple(ok, pid() | undefined, term()) | tuple(error, term())).
restart_app(App) when is_atom(App) ->
    whapps_sup:restart_app(App).

set_amqp_host(H) ->
    amqp_manager:set_host(H).

get_amqp_host() ->
    amqp_manager:get_host().

set_couch_host(H) ->
    set_couch_host(H, "", "").
set_couch_host(H, U, P) ->
    couch_mgr:set_host(whistle_util:to_list(H), whistle_util:to_list(U), whistle_util:to_list(P)).

-spec(running_apps/0 :: () -> list(atom()) | []).
running_apps() ->
    [ App || {App, _, _, _} <- supervisor:which_children(whapps_sup) ].

preload_whapps() ->      
    ?LOG_SYS("loaded whistle controller configuration from ~s", [?STARTUP_FILE]),                  
    {ok, Startup} = file:consult(?STARTUP_FILE),
    WhApps = props:get_value(whapps, Startup, []),
    lists:foreach(fun(WhApp) -> start_app(WhApp) end, WhApps).

%%%===================================================================
%%% Internal functions
%%%===================================================================
