[![GitHub Actions](https://github.com/chrzaszcz/erlang_doctor/actions/workflows/test.yml/badge.svg)](https://github.com/chrzaszcz/erlang_doctor/actions)

## Try it out now in your Erlang shell

To quickly try it out without including it as a dependency, copy & paste the following to your Erlang shell.

```erlang
P = "/tmp/tr.erl", ssl:start(), inets:start(), {ok, {{_, 200, _}, _, Src}} = httpc:request("https://git.io/fj024"), file:write_file(P, Src), {ok, tr, B} = compile:file(P, binary), code:load_binary(tr, P, B), rr(tr), tr:start().
```

This snippet downloads the `tr` module from GitHub, compiles and starts it.
Your Erlang Doctor is now ready to use!

The easiest way to use it is the following:

```erlang
tr:trace_calls([your_module]).
your_module:some_function().
tr:select().
```

You should see the collected traces for the call and return of `your_module:some_function/0`.

This compact tool is capable of much more - see below.

## Include it as an application

To avoid copy-pasting the snippet shown above, you can include `erlang_doctor` in your dependencies in `rebar.config`.
There is a [Hex package](https://hex.pm/packages/erlang_doctor) as well.

## Use it during development

You can make Erlang Doctor available in the Erlang/Rebar3 shell during development by loading it in your `~/.erlang` file:

```erlang
code:add_path("~/dev/erlang_doctor/_build/default/lib/erlang_doctor/ebin").
code:load_file(tr).
```

Alternatively, you can 

## Tracing: data collection

Test suite helpers from `tr_SUITE.erl` are used here as examples.
You can follow these examples on your own - just call `rebar3 shell` in the project root directory.

### Starting the tracer: `start`, `start_link`

The first thing to do is to start the tracer with `tr:start/1`.
There is `tr:start_link/1` as well, but it is intended for use with the whole `erlang_doctor` application.
Both functions can also take a second argument, which is a map with more advanced options:

- `tab`: collected traces are stored in an ETS table with this name (default: `trace`),
- `limit`: maximum number of traces in the table - when it is reached, tracing is stopped.

In this example we start the `tr` module in the simplest way:

```erlang
1> tr:start().
{ok, <0.218.0>}
```

### Tracing function calls: `trace_calls`

To function calls for given modules, use `tr:trace_calls/1`, providing a list of traced modules:

```erlang
3> tr:trace_calls([tr_SUITE]).
ok
```

You can provide `{Module, Function, Arity}` tuples in the list as well.
To get a list of all modules from an application, use `tr:app_modules/1`.
`tr:trace_calls(tr:app_modules(your_app))` would trace all modules from `your_app`.

Now we can call some functions - let's trace the following function call.
It calculates the factorial recursively and sleeps 1 ms between each step.

```erlang
4> tr_SUITE:sleepy_factorial(3).
6
```

### Stop tracing calls

Stop tracing with the following function:

```erlang
5> tr:stop_tracing_calls().
ok
```

It's good to stop it as soon as possible to avoid accumulating too many traces in the ETS table.
Usage of `tr` on production systems is risky, but if you have to do it, start and stop the tracer in the same command,
e.g. for one second with:

```erlang
tr:trace_calls(Modules), timer:sleep(1000), tr:stop_tracing_calls().
```

## Debugging: data analysis

The collected traces are stored in an ETS table (default name: `trace`).
They are stored as `#tr` records with the following fields:

- `index`: trace identifier, auto-incremented for each received trace
- `pid`: process ID associated with the trace
- `event`: `call`, `return_from` or `exception_from`
- `mfa`: an MFA tuple: module name, function name and function arity
- `data`: argument list (for calls), returned value (for returns) or class and value (for exceptions)
- `timestamp` in microseconds

It's useful to read the definition of this record before trace analysis:

```erlang
6> rr(tr).
[tr]
```

The snippet shown at the top of this README includes this already.

### Trace selection: `select`

Use `tr:select/0` to select all collected traces.

```erlang
7> tr:select().
[#tr{index = 1, pid = <0.175.0>, event = call,
     mfa = {tr_SUITE, sleepy_factorial, 1},
     data = [3],
     ts = 1559134178217371},
 #tr{index = 2, pid = <0.175.0>, event = call,
     mfa = {tr_SUITE, sleepy_factorial, 1},
     data = [2],
     ts = 1559134178219102},
 #tr{index = 3, pid = <0.175.0>, event = call,
     mfa = {tr_SUITE, sleepy_factorial, 1},
     data = [1],
     ts = 1559134178221192},
 #tr{index = 4, pid = <0.175.0>, event = call,
     mfa = {tr_SUITE, sleepy_factorial, 1},
     data = [0],
     ts = 1559134178223107},
 #tr{index = 5, pid = <0.175.0>, event = return_from,
     mfa = {tr_SUITE, sleepy_factorial, 1},
     data = 1, ts = 1559134178225146},
 #tr{index = 6, pid = <0.175.0>, event = return_from,
     mfa = {tr_SUITE, sleepy_factorial, 1},
     data = 1, ts = 1559134178225153},
 #tr{index = 7, pid = <0.175.0>, event = return_from,
     mfa = {tr_SUITE, sleepy_factorial, 1},
     data = 2, ts = 1559134178225155},
 #tr{index = 8, pid = <0.175.0>, event = return_from,
     mfa = {tr_SUITE, sleepy_factorial, 1},
     data = 6, ts = 1559134178225156}]
```

The `tr:select/1` function accepts a fun that is passed to `ets:fun2ms/1`.
This way you can limit the selection to specific items and select only some fields from the `tr` record:

```erlang
8> tr:select(fun(#tr{event = call, data = [N]}) -> N end).
[3, 2, 1, 0]
```

Use `tr:select/2` to further filter the results by searching for a term in `#tr.data` (recursively searching in lists, tuples and maps).

```erlang
9> tr:select(fun(T) -> T end, 2).
[#tr{index = 2, pid = <0.175.0>, event = call,
     mfa = {tr_SUITE, sleepy_factorial, 1},
     data = [2],
     ts = 1559134178219102},
 #tr{index = 7, pid = <0.175.0>, event = return_from,
     mfa = {tr_SUITE, sleepy_factorial, 1},
     data = 2, ts = 1559134178225155}]
```

### Trace filtering: `filter`

Sometimes it might be easier to use `tr:filter/1`. You can use e.g. `tr:contains_data/2` to search for a term like in the example above.

```erlang
10> Traces = tr:filter(fun(T) -> tr:contains_data(2, T) end).
[#tr{index = 2, pid = <0.175.0>, event = call,
     mfa = {tr_SUITE, sleepy_factorial, 1},
     data = [2],
     ts = 1559134178219102},
 #tr{index = 7, pid = <0.175.0>, event = return_from,
     mfa = {tr_SUITE, sleepy_factorial, 1},
     data = 2, ts = 1559134178225155}]
```

There is also `tr:filter/2` which can be used to search in a different table than the current one - or in a list:

```erlang
11> tr:filter(fun(#tr{event = call}) -> true end, Traces).
[#tr{index = 2, pid = <0.175.0>, event = call,
     mfa = {tr_SUITE, sleepy_factorial, 1},
     data = [2],
     ts = 1559134178219102}]
```

### Tracebacks for filtered traces: `tracebacks`

To find the tracebacks (call stacks) for matching traces, use `tr:tracebacks/1`:

```erlang
12> tr:tracebacks(fun(#tr{data = 1}) -> true end).
[[#tr{index = 5,pid = <0.219.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [1],
      ts = 1617097424677636},
  #tr{index = 4,pid = <0.219.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [2],
      ts = 1617097424675625},
  #tr{index = 3,pid = <0.219.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [3],
      ts = 1617097424674397}]]
```

Note that by specifying `data = 1` we are only matching return traces as call traces always have a list in `data`.
Only one traceback is returned. It starts with a matching call that returned `1`. What follows is the call stack
for this call.

One can notice that the call for 0 also returned 1, but the call tree gets pruned - whenever two tracebacks overlap, only the shorter one is left.
You can change this by returning tracebacks for all matching traces even if they overlap, setting the `output` option to `all`. All options are included in the second argument, which is a map:

```erlang
13> tr:tracebacks(fun(#tr{data = 1}) -> true end, #{output => all}).
[[#tr{index = 6,pid = <0.219.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [0],
      ts = 1617099584113726},
  #tr{index = 5,pid = <0.219.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [1],
      ts = 1617099584111714},
  #tr{index = 4,pid = <0.219.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [2],
      ts = 1617099584109773},
  #tr{index = 3,pid = <0.219.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [3],
      ts = 1617099584108006}],
 [#tr{index = 5,pid = <0.219.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [1],
      ts = 1617099584111714},
  #tr{index = 4,pid = <0.219.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [2],
      ts = 1617099584109773},
  #tr{index = 3,pid = <0.219.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [3],
      ts = 1617099584108006}]]
```

The third possibility is `output => longest` which does the opposite of pruning, leaving only the longest tracabecks when they overlap:

```erlang
32> tr:tracebacks(fun(#tr{data = 1}) -> true end, #{output => longest}).
[[#tr{index = 6,pid = <0.219.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [0],
      ts = 1617099584113726},
  #tr{index = 5,pid = <0.219.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [1],
      ts = 1617099584111714},
  #tr{index = 4,pid = <0.219.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [2],
      ts = 1617099584109773},
  #tr{index = 3,pid = <0.219.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [3],
      ts = 1617099584108006}]]
```

All possible options for `tracebacks/2`:

- `tab` is the table or list which is like the second argument of `tr:filter/2`,
- `output` - `shortest` (default), `all`, `longest` - see above.
- `format` - `list` (default), `tree` - makes it possible to return the traces in form of a call tree instead of a list of tracebacks. Trees don't distinguish between `all` and `longest` output formats.
- `order` - `top_down` (default), `bottom_up`. Changes call order in each tracaback, only for the `list` format.
- `limit` - positive integer or `infinity` (default). Limits the number of matched traces. The actual number of tracebacks returned can be less unless `output => all`

There are also functions: `traceback/1` and `traceback/2`. They set `limit` to one and return only one trace if it exists. The options for ``traceback/2` are the same as for `traceback/2` except `limit` and `format`. Additionaly, it is possible to pass a `tr` record directly to `traceback/1` to obtain the traceback for the provided trace event.

### Trace ranges for filtered traces: `ranges`

To get the whole traces between the matching call and the corresponding return, use `tr:ranges/1`:

```erlang
14> tr:ranges(fun(#tr{data=[1]}) -> true end).
[[#tr{index = 3, pid = <0.175.0>, event = call,
      mfa = {tr_SUITE, sleepy_factorial, 1},
      data = [1],
      ts = 1559134178221192},
  #tr{index = 4, pid = <0.175.0>, event = call,
      mfa = {tr_SUITE, sleepy_factorial, 1},
      data = [0],
      ts = 1559134178223107},
  #tr{index = 5, pid = <0.175.0>, event = return_from,
      mfa = {tr_SUITE, sleepy_factorial, 1},
      data = 1, ts = 1559134178225146},
  #tr{index = 6, pid = <0.175.0>, event = return_from,
      mfa = {tr_SUITE, sleepy_factorial, 1},
      data = 1, ts = 1559134178225153}]]
```

There is also `tr:ranges/2` - it accepts a map of options with the following keys:

- `tab` is the table or list which is like the second argument of `tr:filter/2`,
- `max_depth` is the maximum depth of nested calls. You can use `#{max_depth => 1}`
   to see only the top-level call and the corresponding return.

There are two additional function: `tr:range/1` and `tr:range/2`, which return only one range if it exists. It is possible to pass a `tr` record to `tr:range/1` as well.

### Calling function from a trace: `do`

It is easy to replay a particular function call with `tr:do/1`:

```erlang
15> [T] = tr:filter(fun(#tr{data = [3]}) -> true end).
[#tr{index = 1, pid = <0.175.0>, event = call,
     mfa = {tr_SUITE, sleepy_factorial, 1},
     data = [3],
     ts = 1559134178217371}]
16> tr:do(T).
6
```

This is useful e.g. for checking if a bug has been fixed without running the whole test suite.

## Profiling

### call_stat

Call statistics - for all calls. The argument of `tr:call_stat/1` is a function that returns a key
by which the traces are grouped.

The simplest way to use this function is to look at the total number of calls and their time.
To do this, we group all calls under one key, e.g. `total`:

```erlang
17> tr:call_stat(fun(_) -> total end).
#{total => {4, 7785, 7785}}
```

Values of the returned map have the following format:

```{call_count(), acc_time(), own_time()}```

In the example there are four calls, which took 7703 microseconds in total.
For nested calls we only take into account the outermost call, so this means that the whole calculation took 7.703 ms.
Let's see how this looks like for individual steps - we can group the stats by the function argument:

```erlang
18> tr:call_stat(fun(#tr{data = [N]}) -> N end).
#{0 => {1, 2039, 2039},
  1 => {1, 3961, 1922},
  2 => {1, 6053, 2092},
  3 => {1, 7785, 1732}}
```

You can use the key function to do any filtering as well:

```erlang
19> tr:call_stat(fun(#tr{data = [N]}) when N < 3 -> N end).
#{0 => {1, 2039, 2039}, 1 => {1, 3961, 1922}, 2 => {1, 6053, 2092}}
```

### sorted_call_stat, print_sorted_call_stat

You can sort the call stat by accumulated time, descending:

```erlang
20> tr:sorted_call_stat(fun(#tr{data = [N]}) -> N end).
[{3, 1, 7785, 1732},
 {2, 1, 6053, 2092},
 {1, 1, 3961, 1922},
 {0, 1, 2039, 2039}]
```

The first element of each tuple is the key, the rest is the same as above.
To pretty print it, use `tr:print_sorted_call_stat/2`.
The second argument limits the table row number, e.g. we can only print the top 3 items:

```erlang
21> tr:print_sorted_call_stat(fun(#tr{data = [N]}) -> N end, 3).
3  1  7785  1732
2  1  6053  2092
1  1  3961  1922
```

## Exporting and importing traces

To get the current table name, use `tr:tab/0`:

```erlang
22> tr:tab().
trace
```

To switch to a new table, use `tr:set_tab/1`. The table need not exist.

```erlang
23> tr:set_tab(tmp).
ok
```

Now you can collect traces to the new table without changing the original one.

```erlang
24> tr:trace_calls([lists]), lists:seq(1, 10), tr:stop_tracing_calls().
ok
25> tr:select().
[#tr{index = 1, pid = <0.175.0>, event = call,
     mfa = {lists, ukeysort, 2},
     data = [1,
             [{'Traces', [#tr{index = 2, pid = <0.175.0>, event = call,
                             mfa = {tr_SUITE, sleepy_factorial, 1},
                             data = [2],

(...)
```

You can dump a table to file with `tr:dump/2` - let's dump the `tmp` table:

```erlang
25> tr:dump("tmp.ets", tmp).
ok
```

In a new Erlang session we can load the data with `tr:load/1`. This will set the current table name to `tmp`.

```erlang
1> tr:start().
{ok, <0.181.0>}
2> tr:load("traces.ets").
{ok, tmp}
3> tr:select().
(...)
4> tr:tab().
tmp
```

Finally, you can remove all traces from the ETS table with `tr:clean/1`.

```erlang
5> tr:clean().
ok
```

To stop `tr`, just call `tr:stop/0`.

# Example use cases

## Debugging a vague error

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

```erlang
(mongooseim@localhost)16> tr:trace_calls([mongoose_ldap_worker]).
ok
```

A few seconds (and error messages) later we can check the traces for the `badkey` value we saw in the logs:

```erlang
(mongooseim@localhost)17> tr:filter(fun(T) -> tr:contains_data(badkey, T) end).
[#tr{index = 255, pid = <0.8118.1>, event = exception_from,
     mfa = {mongoose_ldap_worker, connect, 1},
     data = {error, {badkey, handle}},
     ts = 1557838064073778},
     (...)
```

This means that the key `handle` was missing from a map.
Let's see the traceback to find the exact place in the code:

```erlang
(mongooseim@localhost)18> tr:traceback(fun(T) -> tr:contains_data(badkey, T) end).
[#tr{index = 254, pid = <0.8118.1>, event = call,
     mfa = {mongoose_ldap_worker, connect, 1},
     data = [#{connect_interval => 10000, encrypt => tls, password => <<>>,
               port => 3636, root_dn => <<>>,
               servers => ["localhost"],
               tls_options =>
                   [{verify, verify_peer},
                    {cacertfile, "priv/ssl/cacert.pem"},
                    {certfile, "priv/ssl/fake_cert.pem"},
                    {keyfile, "priv/ssl/fake_key.pem"}]}],
     ts = 1557838064052121}, ...]
```

We can see that the `handle` key is missing from the map passed to `mongoose_ldap_worker:connect/1`.
After looking at the source code of this function and searching for `handle` we can see only one matching line:

```erlang
                    State#{handle := Handle};
```

The `:=` operator assumes that the key is already present in the map.
The solution would be to either change it to `=>` or ensure that the map already contains that key.

## Loading traces to `tr` table after tracing to file

It's possible to use `tr` with a file generated by `dbg:trace_port/2` tracing.
The file may be generated on another system.

```erlang
1> {ok, St} = tr:init({}).
{ok, #{index => 0, traced_modules => []}}
2> dbg:trace_client(file, "/Users/erszcz/work/myproject/long-pong.dbg.trace", {fun tr:handle_trace/2, St}).
<0.178.0>
3> tr:select().
[#tr{index = 1, pid = <14318.7477.2537>, event = call,
     mfa = {mod_ping, user_ping_response_metric, 3},
     data = [{jid, <<"user1">>, <<"myproject.com">>, <<"res1">>,
              <<"user1">>, <<"myproject.com">>, <<"res1">>},
             {iq, <<"EDC1944CF88F67C6">>, result, <<>>, <<"en">>, []},
             5406109],
     ts = 1553517330696515},
...
```

