-record(msg, {to :: pid(), exists :: boolean()}).

-record(tr, {index :: tr:index(),
             pid :: pid(),
             event :: call | return | exception | send | recv,
             mfa :: mfa() | undefined,
             data :: term(),
             ts :: integer(),
             extra :: #msg{} | undefined}).

-record(node, {module :: module(),
               function :: atom(),
               args :: list(),
               children = [] :: [#node{}],
               result :: {return | exception, any()}}).
