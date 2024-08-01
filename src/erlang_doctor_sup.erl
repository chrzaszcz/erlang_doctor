%%%-------------------------------------------------------------------
%% @doc erlang_doctor top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(erlang_doctor_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%% API functions

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%% Supervisor callbacks

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    {ok, {#{}, [tr_spec()]}}.

%% Internal functions

-spec tr_spec() -> supervisor:child_spec().
tr_spec() ->
    #{id => tr,
      start => {tr, start_link, []},
      shutdown => brutal_kill}.
