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

%%====================================================================
%% API functions
%%====================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% Child :: {Id,StartFunc,Restart,Shutdown,Type,Modules}
init([]) ->
    {ok, { {one_for_all, 0, 1},
           [tr_spec()]}
    }.

%%====================================================================
%% Internal functions
%%====================================================================

tr_spec() ->
    {tr,
     {tr, start_link, []},
     permanent,
     brutal_kill,
     worker,
     [tr]}.
