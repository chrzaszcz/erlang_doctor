-record(msg, {to :: pid(), exists :: boolean()}).

-record(tr, {index :: tr:index(),
             pid :: pid(),
             event :: call | return | exception | send | recv,
             mfa = no_mfa :: mfa() | no_mfa,
             data :: term(),
             ts :: integer(),
             info = no_info :: #msg{} | no_info}).

-record(node, {module :: module(),
               function :: atom(),
               args :: list(),
               children = [] :: [#node{}],
               result :: {return | exception, any()}}).
