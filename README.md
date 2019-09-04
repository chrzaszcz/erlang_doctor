# erlang_doctor

Lightweight tracing, debuging and profiling utility for Erlang.

## Usage

### Using as application

Just include `erlang_doctor` in your dependencies.
However, the `tr` module is more frequently used as a small tool on its own.

### Tracing: data collection

Test suite helpers from `tr_SUITE.erl` are used here as examples.
You can follow these examples on your own - just call `./rebar3 shell` in the project root directory.

#### Starting the tracer: `start`, `start_link`

The first thing to do is to start the tracer with `tr:start/1`.
There is `tr:start_link/1` as well, but it is intended for use with the whole `erlang_doctor` application.
Both functions can also take a second argument, which is a map with more advanced options:

- `tab`: collected traces are stored in an ETS table with this name (default: `trace`),
- `limit`: maximum number of traces in the table - when it is reached, tracing is stopped.

In this example we start the `tr` module in the simplest way:

```
1> tr:start().
{ok,<0.218.0>}
```

#### Tracing function calls: `trace_calls`

Make sure the module is loaded before tracing:

```
2> l(tr_SUITE).
{module,tr_SUITE}
```

To trace function calls for given modules, use `tr:trace_calls/1`, providing a list of traced modules:

```
3> tr:trace_calls([tr_SUITE]).
ok
```

You can provide `{Module, Function, Arity}` tuples in the list as well.
To get a list of all modules from an appllication, use `tr:app_modules/1`.

Now we can call some functions - let's trace the following function call.
It calculates the factorial recursively and sleeps 1 ms between each step.

```
4> tr_SUITE:sleepy_factorial(3).
6
```

#### Stop tracing calls

Stop tracing with the following function:

```
5> tr:stop_tracing_calls().
ok
```

It's good to stop it as soon as possible to avoid accumulating too many traces in the ETS table.
Usage of `tr` on production systems is risky, but if you have to do it, start and stop the tracer in the same command,
e.g. for one second with:

```
tr:trace_calls(Modules), timer:sleep(1000), tr:stop_tracing_calls().
```

### Debugging: data analysis

The collected traces are stored in an ETS table (default name: `trace`).
They are stored as `#tr` records with the following fields:

- `index`: trace identifier, auto-incremented for each received trace
- `pid`: process ID associated with the trace
- `event`: `call`, `return_from` or `exception_from`
- `mfa`: an MFA tuple: module name, function name and function arity
- `data`: argument list (for calls), returned value (for returns) or class and value (for exceptions)
- `timestamp` in microseconds

It's useful to read the definition of this record before trace analysis:

```
6> rr(tr).
[tr]
```

#### Trace selection: `select`

Use `tr:select/0` to select all collected traces.

```
7> tr:select().
[#tr{index = 1,pid = <0.175.0>,event = call,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = [3],
     ts = 1559134178217371},
 #tr{index = 2,pid = <0.175.0>,event = call,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = [2],
     ts = 1559134178219102},
 #tr{index = 3,pid = <0.175.0>,event = call,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = [1],
     ts = 1559134178221192},
 #tr{index = 4,pid = <0.175.0>,event = call,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = [0],
     ts = 1559134178223107},
 #tr{index = 5,pid = <0.175.0>,event = return_from,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = 1,ts = 1559134178225146},
 #tr{index = 6,pid = <0.175.0>,event = return_from,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = 1,ts = 1559134178225153},
 #tr{index = 7,pid = <0.175.0>,event = return_from,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = 2,ts = 1559134178225155},
 #tr{index = 8,pid = <0.175.0>,event = return_from,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = 6,ts = 1559134178225156}]
```

The `tr:select/1` function accepts a fun that is passed to `ets:fun2ms/1`.
This way you can limit the selection to specific items and select only some fields from the `tr` record:

```
8> tr:select(fun(#tr{event = call, data = [N]}) -> N end).
[3,2,1,0]
```

Use `tr:select/2` to further filter the results by searching for a term in `#tr.data` (recursively searching in lists, tuples and maps).

```
9> tr:select(fun(T) -> T end, 2).
[#tr{index = 2,pid = <0.175.0>,event = call,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = [2],
     ts = 1559134178219102},
 #tr{index = 7,pid = <0.175.0>,event = return_from,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = 2,ts = 1559134178225155}]
```

#### Trace filtering: `filter`

Sometimes it might be easier to use `tr:filter/1`. You can use e.g. `tr:contains_data/2` to search for a term like in the example above.



```
10> Traces = tr:filter(fun(T) -> tr:contains_data(2, T) end).
[#tr{index = 2,pid = <0.175.0>,event = call,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = [2],
     ts = 1559134178219102},
 #tr{index = 7,pid = <0.175.0>,event = return_from,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = 2,ts = 1559134178225155}]
```

There is also `tr:filter/2` which can be used to search in a different table than the current one - or in a list:

```
11> tr:filter(fun(#tr{event = call}) -> true end, Traces).
[#tr{index = 2,pid = <0.175.0>,event = call,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = [2],
     ts = 1559134178219102}]
```

#### Tracebacks for filtered traces: `filter_tracebacks`

To find the traceback (call stack trace) for matching traces, use `tr:filter_tracebacks/1`:

```
12> Tracebacks = tr:filter_tracebacks(fun(#tr{data = 1}) -> true end).
[[#tr{index = 1,pid = <0.175.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [3],
      ts = 1559134178217371},
  #tr{index = 2,pid = <0.175.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [2],
      ts = 1559134178219102},
  #tr{index = 3,pid = <0.175.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [1],
      ts = 1559134178221192},
  #tr{index = 4,pid = <0.175.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [0],
      ts = 1559134178223107}],
 [#tr{index = 1,pid = <0.175.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [3],
      ts = 1559134178217371},
  #tr{index = 2,pid = <0.175.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [2],
      ts = 1559134178219102},
  #tr{index = 3,pid = <0.175.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [1],
      ts = 1559134178221192}]]
```

Note that by specifying `data = 1` we are only matching return traces as call traces always have a list in `data`.
We got two tracebacks (see the nested lists) as there were two function calls which returned the value `1`.

```
13> [[N || #tr{data=[N]} <- TB] || TB <- Tracebacks].
[[3,2,1,0],[3,2,1]]
```

There is also `tr:filter_tracebacks/2` which works like `tr:filter/2`.

#### Trace ranges for filtered traces: `filter_ranges`

To get the whole traces between the matching call and the corresponding return, use `tr:filter_ranges/1`:

```
14> tr:filter_ranges(fun(#tr{data=[1]}) -> true end).
[[#tr{index = 3,pid = <0.175.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [1],
      ts = 1559134178221192},
  #tr{index = 4,pid = <0.175.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [0],
      ts = 1559134178223107},
  #tr{index = 5,pid = <0.175.0>,event = return_from,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = 1,ts = 1559134178225146},
  #tr{index = 6,pid = <0.175.0>,event = return_from,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = 1,ts = 1559134178225153}]]
```

There is also `tr:filter_ranges/2` - it accepts a map of options with the following keys:

- `tab` is the table or list which is like the second argument of `tr:filter/2`,
- `max_depth` is the maximum depth of nested calls. You can use `#{max_depth => 1}`
   to see only the top-level call and the corresponding return.

#### Calling function from a trace: `do`

It is easy to replay a particular function call with `tr:do/1`:

```
15> [T] = tr:filter(fun(#tr{data = [3]}) -> true end).
[#tr{index = 1,pid = <0.175.0>,event = call,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = [3],
     ts = 1559134178217371}]
16> tr:do(T).
6
```

This is useful e.g. for checking if a bug has been fixed without running the whole test suite.

### Profiling

#### call_stat

Call statistics - for all calls. The argument of `tr:call_stat/1` is a function that returns a key
by which the traces are grouped.

The simplest way to use this function is to look at the total number of calls and their time.
To do this, we group all calls under one key, e.g. `total`:

```
17> tr:call_stat(fun(_) -> total end).
#{total => {4,7785,7785}}
```

Values of the returned map have the following format:

```{call_count(), acc_time(), own_time()}```

In the example there are four calls, which took 7703 microseconds in total.
For nested calls we only take into account the outermost call, so this means that the whole calculation took 7.703 ms.
Let's see how this looks like for individual steps - we can group the stats by the function argument:

```
18> tr:call_stat(fun(#tr{data = [N]}) -> N end).
#{0 => {1,2039,2039},
  1 => {1,3961,1922},
  2 => {1,6053,2092},
  3 => {1,7785,1732}}
```

You can use the key function to do any filtering as well:

```
19> tr:call_stat(fun(#tr{data = [N]}) when N < 3 -> N end).
#{0 => {1,2039,2039},1 => {1,3961,1922},2 => {1,6053,2092}}
```

#### sorted_call_stat, print_sorted_call_stat

You can sort the call stat by accumulated time, descending:

```
20> tr:sorted_call_stat(fun(#tr{data = [N]}) -> N end).
[{3,1,7785,1732},
 {2,1,6053,2092},
 {1,1,3961,1922},
 {0,1,2039,2039}]
```

The first element of each tuple is the key, the rest is the same as above.
To pretty print it, use `tr:print_sorted_call_stat/2`.
The second argument limits the table row number, e.g. we can only print the top 3 items:

```
21> tr:print_sorted_call_stat(fun(#tr{data = [N]}) -> N end, 3).
3  1  7785  1732
2  1  6053  2092
1  1  3961  1922
```

### Exporting and importing traces

To get the current table name, use `tr:tab/0`:

```
22> tr:tab().
trace
```

To switch to a new table, use `tr:set_tab/1`. The table need not exist.

```
23> tr:set_tab(tmp).
ok
```

Now you can collect traces to the new table without changing the original one.

```
24> tr:trace_calls([lists]), lists:seq(1,10), tr:stop_tracing_calls().
ok
25> tr:select().
[#tr{index = 1,pid = <0.175.0>,event = call,
     mfa = {lists,ukeysort,2},
     data = [1,
             [{'Traces',[#tr{index = 2,pid = <0.175.0>,event = call,
                             mfa = {tr_SUITE,sleepy_factorial,1},
                             data = [2],

(...)
```

You can dump a table to file with `tr:dump/2` - let's dump the `tmp` table:

```
25> tr:dump("tmp.ets", tmp).
ok
```

In a new Erlang session we can load the data with `tr:load/1`. This will set the current table name to `tmp`.

```
1> tr:start().
{ok,<0.181.0>}
2> tr:load("traces.ets").
{ok,tmp}
3> tr:select().
(...)
4> tr:tab().
tmp
```

Finally, you can remove all traces from the ETS table with `tr:clean/1`.

```
5> tr:clean().
ok
```

To stop `tr`, just call `tr:stop/0`.

## Example use cases

### Download and start `tr` on a system that is already running

```
1> P="/tmp/tr.erl", ssl:start(), inets:start(), {ok, {{_, 200, _}, _, Src}} = httpc:request("https://git.io/fj024"), file:write_file(P, Src), {ok, tr, B} = compile:file(P, binary), code:load_binary(tr, P, B), rr(tr), tr:start().
ok
```

### Debugging a vague error

While reworking the LDAP connection layer in [MongooseIM](https://github.com/esl/MongooseIM), the following error occured in the logs:

```
14:46:35.002 [warning] lager_error_logger_h dropped 79 messages in the last second that exceeded the limit of 50 messages/sec
14:46:35.002 [error] gen_server 'wpool_pool-mongoose_wpool$ldap$global$bind-1' terminated with reason: no case clause matching {badkey,handle} in wpool_process:handle_info/2 line 123
14:46:35.003 [error] CRASH REPORT Process 'wpool_pool-mongoose_wpool$ldap$global$bind-1' with 1 neighbours crashed with reason: no case clause matching {badkey,handle} in wpool_process:handle_info/2 line 123
14:46:35.003 [error] Supervisor 'wpool_pool-mongoose_wpool$ldap$global$bind-process-sup' had child 'wpool_pool-mongoose_wpool$ldap$global$bind-1' started with wpool_process:start_link('wpool_pool-mongoose_wpool$ldap$global$bind-1', mongoose_ldap_worker, [{port,3636},{encrypt,tls},{tls_options,[{verify,verify_peer},{cacertfile,"priv/ssl/cacert.pem"},...]}], [{queue_manager,'wpool_pool-mongoose_wpool$ldap$global$bind-queue-manager'},{time_checker,'wpool_pool-mongoose_wpool$ldap$global$bind-time-checker'},...]) at <0.28894.0> exit with reason no case clause matching {badkey,handle} in wpool_process:handle_info/2 line 123 in context child_terminated
14:46:35.009 [info] Connected to LDAP server
14:46:35.009 [error] gen_server 'wpool_pool-mongoose_wpool$ldap$global$default-1' terminated with reason: no case clause matching {badkey,handle} in wpool_process:handle_info/2 line 123
14:46:35.009 [error] CRASH REPORT Process 'wpool_pool-mongoose_wpool$ldap$global$default-1' with 1 neighbours crashed with reason: no case clause matching {badkey,handle} in wpool_process:handle_info/2 line 123
```

As this messages appear every 10 seconds (on each attempt to reconnect to LDAP), we can start tracing.
The most lkely culprit is the `mongoose_ldap_worker` module, so let's trace it:

```
(mongooseim@localhost)16> tr:trace_calls([mongoose_ldap_worker]).
ok
```

A few seconds (and error messages) later we can check the traces for the `badkey` value we saw in the logs:

```
(mongooseim@localhost)17> tr:filter(fun(T) -> tr:contains_data(badkey, T) end).
[#tr{index = 255,pid = <0.8118.1>,event = exception_from,
     mfa = {mongoose_ldap_worker,connect,1},
     data = {error,{badkey,handle}},
     ts = 1557838064073778},
     (...)
```

This means that the key `handle` was missing from a map.
Let's see the traceback to find the exact place in the code:

```
(mongooseim@localhost)18> hd(tr:filter_tracebacks(fun(T) -> tr:contains_data(badkey, T) end)).
[#tr{index = 253,pid = <0.8118.1>,event = call,
     mfa = {mongoose_ldap_worker,handle_info,2},
     data = [connect,
             #{connect_interval => 10000,encrypt => tls,password => <<>>,
               port => 3636,root_dn => <<>>,
               servers => ["localhost"],
               tls_options =>
                   [{verify,verify_peer},
                    {cacertfile,"priv/ssl/cacert.pem"},
                    {certfile,"priv/ssl/fake_cert.pem"},
                    {keyfile,"priv/ssl/fake_key.pem"}]}],
     ts = 1557838064052116},
 #tr{index = 254,pid = <0.8118.1>,event = call,
     mfa = {mongoose_ldap_worker,connect,1},
     data = [#{connect_interval => 10000,encrypt => tls,password => <<>>,
               port => 3636,root_dn => <<>>,
               servers => ["localhost"],
               tls_options =>
                   [{verify,verify_peer},
                    {cacertfile,"priv/ssl/cacert.pem"},
                    {certfile,"priv/ssl/fake_cert.pem"},
                    {keyfile,"priv/ssl/fake_key.pem"}]}],
     ts = 1557838064052121}]
```

We can see that the `handle` key is missing from the map passed to `mongoose_ldap_worker:connect/1`.
After looking at the source code of this function and searching for `handle` we can see only one matching line:

```
                    State#{handle := Handle};
```

The `:=` operator assumes that the key is already present in the map.
The solution would be to either change it to `=>` or ensure that the map already contains that key.

### Loading traces to `tr` table after tracing to file

It's possible to use `tr` with a file generated by `dbg:trace_port/2` tracing.
The file may be generated on another system.

```
1> {ok, St} = tr:init({}).
{ok, #{index => 0,traced_modules => []}}
2> dbg:trace_client(file, "/Users/erszcz/work/myproject/long-pong.dbg.trace", {fun tr:handle_trace/2, St}).
<0.178.0>
3>
3> ets:tab2list(trace).
[{tr,1,<14318.7477.2537>,call,
     {mod_ping,user_ping_response_metric,3},
     [{jid,<<"user1">>,<<"myproject.com">>,<<"res1">>,
           <<"user1">>,<<"myproject.com">>,<<"res1">>},
      {iq,<<"EDC1944CF88F67C6">>,result,<<>>,<<"en">>,[]},
      5406109],
     1553517330696515},
...
```

