# Erlang Doctor

[![Hex.pm Version](https://img.shields.io/hexpm/v/erlang_doctor)](https://hex.pm/packages/erlang_doctor)
[![Hex Docs](https://img.shields.io/badge/hex-docs-yellow.svg)](https://hexdocs.pm/erlang_doctor/)
[![GitHub Actions](https://github.com/chrzaszcz/erlang_doctor/actions/workflows/test.yml/badge.svg)](https://github.com/chrzaszcz/erlang_doctor/actions)

Lightweight tracing, debugging and profiling tool, which collects traces in an ETS table, putting minimal impact on your system.
After collecting the traces, you can query and analyse them.
By separating data collection from analysis, this tool helps you limit unnecessary repetition and guesswork.
There is [ExDoctor](https://hex.pm/packages/ex_doctor) for Elixir as well.

## Quick start

To quickly try it out right now, copy & paste the following to your Erlang shell:

```erlang
P = "/tmp/tr.erl", ssl:start(), inets:start(), {ok, {{_, 200, _}, _, Src}} = httpc:request("https://git.io/fj024"), file:write_file(P, Src), {ok, tr, B} = compile:file(P, binary), code:load_binary(tr, P, B), rr(P), tr:start().
```

This snippet downloads, compiles and starts the `tr` module from the `master` branch.
Your Erlang Doctor is now ready to use!

The easiest way to use it is the following:

```erlang
tr:trace([your_module]).
your_module:some_function().
tr:select().
```

You should see the collected traces for the call and return of `your_module:some_function/0`.

This compact tool is capable of much more - see below.

### Include it as a dependency

To avoid copy-pasting the snippet shown above, you can include `erlang_doctor` in your dependencies in `rebar.config`.
There is a [Hex package](https://hex.pm/packages/erlang_doctor) as well.

### Use it during development

You can make Erlang Doctor available in the Erlang/Rebar3 shell during development by cloning it to `ERLANG_DOCTOR_PATH`,
calling `rebar3 compile`, and loading it in your `~/.erlang` file:

```erlang
code:add_path("ERLANG_DOCTOR_PATH/erlang_doctor/_build/default/lib/erlang_doctor/ebin").
code:load_file(tr).
```

## Tracing: data collection

The test suite helpers from `tr_SUITE.erl` are used here as examples.
You can follow these examples on your own - just call `rebar3 as test shell` in `ERLANG_DOCTOR_PATH`.

### Setting up: `start`, `start_link`

The first thing to do is to start the tracer with `tr:start/0`.

There is also `tr:start/1`, which accepts a [map of options](https://hexdocs.pm/erlang_doctor/0.3.1/tr.html#t:init_options/0), including:

- `tab`: collected traces are stored in an ETS table with this name (default: `trace`),
- `limit`: maximum number of traces in the table - when it is reached, tracing is stopped (default: no limit).

There are `tr:start_link/0` and `tr:start_link/1` as well, and they are intended for use with the whole `erlang_doctor` application.

For this tutorial we start the `tr` module in the simplest way:

```erlang
1> tr:start().
{ok, <0.218.0>}
```

### Tracing with `trace`

To trace function calls for given modules, use `tr:trace/1`, providing a list of traced modules:

```erlang
2> tr:trace([tr_SUITE]).
ok
```

You can provide `{Module, Function, Arity}` tuples in the list as well.
The function `tr:trace_app/1` traces an application, and `tr:trace_apps/1` traces multiple ones.
If you need to trace an application and some additional modules, use `tr:app_modules/1` to get the list of modules for an application:

```erlang
tr:trace([Module1, Module2 | tr:app_modules(YourApp)]).
```

If you want to trace selected processes instead of all of them, you can use `tr:trace/2`:

```erlang
tr:trace([Module1, Module2], [Pid1, Pid2]).
```

The `tr:trace/1` function accepts a [map of options](https://hexdocs.pm/erlang_doctor/0.3.1/tr.html#t:trace_options/0), which include:

- `modules`: a list of module names or `{Module, Function, Arity}` tuples. The list is empty by default.
- `pids`: a list of Pids of processes to trace, or the atom `all` (default) to trace all processes.
- `msg`: `none` (default), `all`, `send` or `recv`. Specifies which message events will be traced. By default no messages are traced.
- `msg_trigger`: `after_traced_call` (default) or `always`. By default, traced messages in each process are stored after the first traced function call in that process. The goal is to limit the number of traced messages, which can be huge in the entire Erlang system. If you want all messages, set it to `always`.

### Calling the traced function

Now we can call some functions - let's trace the following function call.
It calculates the factorial recursively and sleeps 1 ms between each step.

```erlang
3> tr_SUITE:sleepy_factorial(3).
6
```

### Stopping tracing

You can stop tracing with the following function:

```erlang
4> tr:stop_tracing().
ok
```

It's good to stop it as soon as possible to avoid accumulating too many traces in the ETS table.
Usage of `tr` on production systems is risky, but if you have to do it, start and stop the tracer in the same command,
e.g. for one second with:

```erlang
tr:trace(Modules), timer:sleep(1000), tr:stop_tracing().
```

## Debugging: data analysis

The collected traces are stored in an ETS table (default name: `trace`).
They are stored as [`tr`](https://hexdocs.pm/erlang_doctor/0.3.1/tr.html#t:tr/0) records with the following fields:

- `index`: trace identifier, auto-incremented for each received trace.
- `pid`: process identifier associated with the trace.
- `event`: `call`, `return` or `exception` for function traces; `send` or `recv` for messages.
- `mfa`: `{Module, Function, Arity}` for function traces; `no_mfa` for messages.
- `data`: argument list (for calls), returned value (for returns) or class and value (for exceptions).
- `timestamp` in microseconds.
- `info`: For function traces and `recv` events it is `no_info`. For `send` events it is a `{To, Exists}` tuple, where `To` is the recipient pid, and `Exists` is a boolean indicating if the recipient process existed.

It's useful to read the record definitions before trace analysis:

```erlang
5> rr(tr).
[node,tr]
```

The snippet shown at the top of this page includes this already.

### Trace selection: `select`

Use `tr:select/0` to select all collected traces.

```erlang
6> tr:select().
[#tr{index = 1,pid = <0.395.0>,event = call,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = [3],
     ts = 1705475521743239,info = no_info},
 #tr{index = 2,pid = <0.395.0>,event = call,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = [2],
     ts = 1705475521744690,info = no_info},
 #tr{index = 3,pid = <0.395.0>,event = call,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = [1],
     ts = 1705475521746470,info = no_info},
 #tr{index = 4,pid = <0.395.0>,event = call,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = [0],
     ts = 1705475521748499,info = no_info},
 #tr{index = 5,pid = <0.395.0>,event = return,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = 1,ts = 1705475521750451,info = no_info},
 #tr{index = 6,pid = <0.395.0>,event = return,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = 1,ts = 1705475521750453,info = no_info},
 #tr{index = 7,pid = <0.395.0>,event = return,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = 2,ts = 1705475521750454,info = no_info},
 #tr{index = 8,pid = <0.395.0>,event = return,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = 6,ts = 1705475521750455,info = no_info}]
```

The `tr:select/1` function accepts a fun that is passed to `ets:fun2ms/1`.
This way you can limit the selection to specific items and select only some fields from the [`tr`](https://hexdocs.pm/erlang_doctor/0.3.1/tr.html#t:tr/0) record:

```erlang
7> tr:select(fun(#tr{event = call, data = [N]}) -> N end).
[3, 2, 1, 0]
```

Use `tr:select/2` to further filter the results by searching for a term in `#tr.data` (recursively searching in lists, tuples and maps).

```erlang
8> tr:select(fun(T) -> T end, 2).
[#tr{index = 2,pid = <0.395.0>,event = call,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = [2],
     ts = 1705475521744690,info = no_info},
 #tr{index = 7,pid = <0.395.0>,event = return,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = 2,ts = 1705475521750454,info = no_info}]
```

### Trace filtering: `filter`

Sometimes it might be easier to use `tr:filter/1`, because it can accept any function as the argument.
You can use `tr:contains_data/2` to search for the same term as in the example above.

```erlang
9> Traces = tr:filter(fun(T) -> tr:contains_data(2, T) end).
[#tr{index = 2,pid = <0.395.0>,event = call,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = [2],
     ts = 1705475521744690,info = no_info},
 #tr{index = 7,pid = <0.395.0>,event = return,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = 2,ts = 1705475521750454,info = no_info}]
```

The provided function is a predicate, which has to return `true` for the matching traces.
For other traces it can return another value, or even raise an exception:

```erlang
10> tr:filter(fun(#tr{data = [2]}) -> true end).
[#tr{index = 2,pid = <0.395.0>,event = call,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = [2],
     ts = 1705475521744690,info = no_info}]
```

There is also `tr:filter/2`, which can be used to search in a different table than the current one - or in a list:

```erlang
11> tr:filter(fun(#tr{event = call}) -> true end, Traces).
[#tr{index = 2,pid = <0.395.0>,event = call,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = [2],
     ts = 1705475521744690,info = no_info}]
```

There are also additional ready-to-use predicates besides `tr:contains_data/2`:

1. `tr:match_data/2` performs a recursive check for terms like `tr:contains_data/2`,
  but instead of checking for equality, it applies the predicate function
  provided as the first argument to each term, and returns `true` if the predicate returned `true`
  for any of them. The predicate can return any other value or fail for non-matching terms.
1. `tr:contains_val/2` is like `tr:contains_data/2`, but the second argument is the `Data` term itself rather than a trace record with data.
2. `tr:match_val/2` is like `tr:match_data/2`, but the second argument is the `Data` term itself rather than a trace record with data.

By combining these predicates, you can search for complex terms, e.g.
the following expression returns trace records that contain any (possibly nested in tuples/lists/maps)
3-element tuples with a map as the third element - and that map has to contain the atom `error`
(possibly nested in tuples/lists/maps).


```erlang
tr:filter(fun(T) -> tr:match_data(fun({_, _, Map = #{}}) -> tr:contains_val(error, Map) end, T) end).
```

### Tracebacks for filtered traces: `tracebacks`

To find the tracebacks (stack traces) for matching traces, use `tr:tracebacks/1`:

```erlang
12> tr:tracebacks(fun(#tr{data = 1}) -> true end).
[[#tr{index = 3,pid = <0.395.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [1],
      ts = 1705475521746470,info = no_info},
  #tr{index = 2,pid = <0.395.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [2],
      ts = 1705475521744690,info = no_info},
  #tr{index = 1,pid = <0.395.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [3],
      ts = 1705475521743239,info = no_info}]]
```

Note, that by specifying `data = 1` we are only matching return traces, as call traces always have a list in `data`.
Only one traceback is returned. It starts with a call that returned `1`. What follows is the stack trace for this call.

One can notice that the call for 0 also returned 1, but the call tree got pruned - whenever two tracebacks overlap, only the shorter one is left.
You can change this by returning tracebacks for all matching traces even if they overlap, setting the `output` option to `all`. All options are specified in the second argument, which is a map:

```erlang
13> tr:tracebacks(fun(#tr{data = 1}) -> true end, #{output => all}).
[[#tr{index = 4,pid = <0.395.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [0],
      ts = 1705475521748499,info = no_info},
  #tr{index = 3,pid = <0.395.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [1],
      ts = 1705475521746470,info = no_info},
  #tr{index = 2,pid = <0.395.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [2],
      ts = 1705475521744690,info = no_info},
  #tr{index = 1,pid = <0.395.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [3],
      ts = 1705475521743239,info = no_info}],
 [#tr{index = 3,pid = <0.395.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [1],
      ts = 1705475521746470,info = no_info},
  #tr{index = 2,pid = <0.395.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [2],
      ts = 1705475521744690,info = no_info},
  #tr{index = 1,pid = <0.395.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [3],
      ts = 1705475521743239,info = no_info}]]
```

The third possibility is `output => longest` which does the opposite of pruning, leaving only the longest tracabecks when they overlap:

```erlang
14> tr:tracebacks(fun(#tr{data = 1}) -> true end, #{output => longest}).
[[#tr{index = 4,pid = <0.395.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [0],
      ts = 1705475521748499,info = no_info},
  #tr{index = 3,pid = <0.395.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [1],
      ts = 1705475521746470,info = no_info},
  #tr{index = 2,pid = <0.395.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [2],
      ts = 1705475521744690,info = no_info},
  #tr{index = 1,pid = <0.395.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [3],
      ts = 1705475521743239,info = no_info}]]
```

Possible [options](https://hexdocs.pm/erlang_doctor/0.3.1/tr.html#t:tb_options/0) for `tr:tracebacks/2` include:

- `tab` is the table or list which is like the second argument of `tr:filter/2`,
- `output` - `shortest` (default), `all`, `longest` - see above.
- `format` - `list` (default), `tree` - returns a list of (possibly merged) call trees instead of tracebacks, `root` - returns a list of root calls. Trees and roots don't distinguish between `all` and `longest` output formats. Using `root` is equivalent to using `tree`, and then calling `tr:roots/1` on the results. There is also `tr:root/1` for a single tree.
- `order` - `top_down` (default), `bottom_up` - call order in each tracaback; only for the `list` format.
- `limit` - positive integer or `infinity` (default) - limits the number of matched traces. The actual number of tracebacks returned can be smaller unless `output => all`

There are also functions `tr:traceback/1` and `tr:traceback/2`. They set `limit` to one and return only one trace if it exists. The options for `tr:traceback/2` are the same as for `tr:traceback/2` except `limit` and `format` (which are not supported). Additionally, it is possible to pass a [`tr`](https://hexdocs.pm/erlang_doctor/0.3.1/tr.html#t:tr/0) record (or an index) as the first argument to `tr:traceback/1` or `tr:traceback/2` to obtain the traceback for the provided trace event.

### Trace ranges for filtered traces: `ranges`

To get a list of traces between each matching call and the corresponding return, use `tr:ranges/1`:

```erlang
15> tr:ranges(fun(#tr{data = [1]}) -> true end).
[[#tr{index = 3,pid = <0.395.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [1],
      ts = 1705475521746470,info = no_info},
  #tr{index = 4,pid = <0.395.0>,event = call,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = [0],
      ts = 1705475521748499,info = no_info},
  #tr{index = 5,pid = <0.395.0>,event = return,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = 1,ts = 1705475521750451,info = no_info},
  #tr{index = 6,pid = <0.395.0>,event = return,
      mfa = {tr_SUITE,sleepy_factorial,1},
      data = 1,ts = 1705475521750453,info = no_info}]]
```

There is also `tr:ranges/2` - it accepts a [map of options](https://hexdocs.pm/erlang_doctor/0.3.1/tr.html#t:range_options/0), including:

- `tab` is the table or list which is like the second argument of `tr:filter/2`,
- `max_depth` is the maximum depth of nested calls. A message event also adds 1 to the depth.
    You can use `#{max_depth => 1}` to see only the top-level call and the corresponding return.
- `output` - `all` (default), `complete` or `incomplete` - decides whether the output should contain
    complete and/or incomplete ranges. A range is complete if the root call has a return.
    For example, you can use `#{output => incomplete}` to see only the traces with missing returns.

When you combine the options into `#{output => incomplete, max_depth => 1}`,
you get all the calls which didn't return (they were still executing when tracing was stopped).

There are two additional functions: `tr:range/1` and `tr:range/2`, which return only one range if it exists. It is possible to pass a [`tr`](https://hexdocs.pm/erlang_doctor/0.3.1/tr.html#t:tr/0) record or an index as the first argument to `tr:range/1` or `tr:range/2` as well.

### Calling a function from a trace: `do`

It is easy to replay a particular function call with `tr:do/1`:

```erlang
16> [T] = tr:filter(fun(#tr{data = [3]}) -> true end).
[#tr{index = 1,pid = <0.395.0>,event = call,
     mfa = {tr_SUITE,sleepy_factorial,1},
     data = [3],
     ts = 1705475521743239,info = no_info}]
17> tr:do(T).
6
```

This is useful e.g. for checking if a bug has been fixed without running the whole test suite.
This function can be called with an index as the argument.

### Browsing traces: `lookup`, `prev`, `next`

Use `tr:lookup/1` to obtain the trace record for an index. Also, given a trace record or an index,
you can obtain the next trace record with `tr:next/1`, or the previous one with `tr:prev/1`.

```erlang
18> T2 = tr:next(T).
#tr{index = 2,pid = <0.424.0>,event = call,
    mfa = {tr_SUITE,sleepy_factorial,1},
    data = [2],
    ts = 1752566205078116,info = no_info}
19> T = tr:prev(T2).
#tr{index = 1,pid = <0.424.0>,event = call,
    mfa = {tr_SUITE,sleepy_factorial,1},
    data = [3],
    ts = 1752566205069393,info = no_info}
```

When there is no trace to return, `not_found` error is raised:

```erlang
20> tr:prev(T).
** exception error: not_found
     in function  tr:prev/3
        called as tr:prev(1,#Fun<tr.15.31036569>,trace)
```

There are also more advanced variants of these fucntions: `tr:next/2` and `tr:prev/2`.
As their second argument, they take a [map of options](https://hexdocs.pm/erlang_doctor/0.3.1/tr.html#t:prev_next_options/0), including:

- `tab` is the table or list (like the second argument of `tr:filter/2`),
- `pred` is a predicate function that should return `true` for a matching trace record.
    For other arguments, it can return a different value or fail.
    When used, `tab` will be traversed until a matching trace is found.

There are also functions `tr:seq_next/1` and `tr:seq_prev/1`.
Given a trace record or an index, they first check the `Pid` of the process for that trace record,
and then they return next/previous trace record with the same `Pid`.
This effect could be achieved with a predicate function: `fun(#tr{pid = P}) -> P =:= Pid end`,
but these utility functions are much more handy.

## Profiling

You can quickly get a hint about possible bottlenecks and redundancies in your system with function call statistics.

### Call statistics: `call_stat`

The argument of `tr:call_stat/1` is a function that returns a key by which the traces are grouped.
The simplest way to use this function is to look at the total number of calls and their time.
To do this, we group all calls under one key, e.g. `total`:

```erlang
21> tr:call_stat(fun(_) -> total end).
#{total => {4,7216,7216}}
```

Values of the returned map have the following format (time is in microseconds):

```{call_count(), acc_time(), own_time()}```

In the example there are four calls, which took 7216 microseconds in total.
For nested calls we only take into account the outermost call, so this means that the whole calculation took 7.216 ms.
Let's see how this looks like for individual steps - we can group the stats by the function argument:

```erlang
22> tr:call_stat(fun(#tr{data = [N]}) -> N end).
#{0 => {1,1952,1952},
  1 => {1,3983,2031},
  2 => {1,5764,1781},
  3 => {1,7216,1452}}
```

You can use the provided function to do filtering as well:

```erlang
23> tr:call_stat(fun(#tr{data = [N]}) when N < 3 -> N end).
#{0 => {1,1952,1952},1 => {1,3983,2031},2 => {1,5764,1781}}
```

### Sorted call statistics: `sorted_call_stat`

You can sort the call stat by accumulated time (descending) with `tr:sorted_call_stat/1`:

```erlang
24> tr:sorted_call_stat(fun(#tr{data = [N]}) -> N end).
[{3,1,7216,1452},
 {2,1,5764,1781},
 {1,1,3983,2031},
 {0,1,1952,1952}]
```

The first element of each tuple is the key, the rest is the same as above.
To pretty-print it, use `tr:print_sorted_call_stat/2`.
The second argument limits the table row number, e.g. we can only print the top 3 items:

```erlang
25> tr:print_sorted_call_stat(fun(#tr{data = [N]}) -> N end, 3).
3  1  7216  1452
2  1  5764  1781
1  1  3983  2031
ok
```

### Call tree statistics: `top_call_trees`

The function `tr:top_call_trees/0` makes it possible to detect complete call trees that repeat several times,
where corresponding function calls and returns have the same arguments and return values, respectively.
When such functions take a lot of time and do not have useful side effects, they can be often optimized.

As an example, let's trace the call to a function which calculates the 4th element of the Fibonacci Sequence
in a recursive way. The `trace` table should be empty, so let's clean it up first:

```erlang
26> tr:clean().
ok
27> tr:trace([tr_SUITE]).
ok
28> tr_SUITE:fib(4).
3
29> tr:stop_tracing().
ok
```

Now it is possible to print the most time consuming call trees that repeat at least twice:

```erlang
30> tr:top_call_trees().
[{13,2,
  #node{module = tr_SUITE,function = fib,
        args = [2],
        children = [#node{module = tr_SUITE,function = fib,
                          args = [1],
                          children = [],
                          result = {return,1}},
                    #node{module = tr_SUITE,function = fib,
                          args = [0],
                          children = [],
                          result = {return,0}}],
        result = {return,1}}},
 {5,3,
  #node{module = tr_SUITE,function = fib,
        args = [1],
        children = [],
        result = {return,1}}}]
```

The resulting list contains tuples `{Time, Count, Tree}` where `Time` is the accumulated time (in microseconds) spent in the tree,
and `Count` is the number of times the tree repeated. The list is sorted by `Time`, descending.
In the example above `fib(2)` was called twice and `fib(1)` was called 3 times,
what already shows that the recursive implementation is suboptimal.

There is also `tr:top_call_trees/1`, which takes a [map of options](https://hexdocs.pm/erlang_doctor/0.3.1/tr.html#t:top_call_trees_options/0), including:
- `output` is `reduced` by default, but it can be set to `complete` where subtrees of already listed trees are also listed.
- `min_count` is the minimum number of times a tree has to occur to be listed, the default is 2.
- `min_time` is the minimum accumulated time for a tree, by default there is no minimum.
- `max_size` is the maximum number of trees presented, the default is 10.

As an exercise, try calling `tr:top_call_trees(#{min_count => 1000})` for `fib(20)`.

## Exporting and importing traces

To get the current table name, use `tr:tab/0`:

```erlang
31> tr:tab().
trace
```

To switch to a new table, use `tr:set_tab/1`. The table need not exist.

```erlang
32> tr:set_tab(tmp).
ok
```

Now you can collect traces to the new table without changing the original one.

```erlang
33> tr:trace([lists]), lists:seq(1, 10), tr:stop_tracing().
ok
34> tr:select().
[#tr{index = 1, pid = <0.175.0>, event = call,
     mfa = {lists, ukeysort, 2},
     data = [1,
             [{'Traces', [#tr{index = 2, pid = <0.175.0>, event = call,
                             mfa = {tr_SUITE, sleepy_factorial, 1},
                             data = [2],
(...)
```

You can dump a table to file with `tr:dump/1` - let's dump the `tmp` table:

```erlang
35> tr:dump("tmp.ets").
ok
```

In a new Erlang session we can load the data with `tr:load/1`. This will set the current table name to `tmp`.

```erlang
1> tr:start().
{ok, <0.181.0>}
2> tr:load("tmp.ets").
{ok, tmp}
3> tr:select().
(...)
4> tr:tab().
tmp
```

Finally, you can remove all traces from the ETS table with `tr:clean/0`.

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
(mongooseim@localhost)16> tr:trace([mongoose_ldap_worker]).
ok
```

A few seconds (and error messages) later we can check the traces for the `badkey` value we saw in the logs:

```erlang
(mongooseim@localhost)17> tr:filter(fun(T) -> tr:contains_data(badkey, T) end).
[#tr{index = 255, pid = <0.8118.1>, event = exception,
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

## Loading traces to the `trace` table after tracing to file

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
