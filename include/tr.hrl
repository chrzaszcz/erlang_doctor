-record(tr, {index :: pos_integer(),
             pid :: pid(),
             event :: call | return_from | exception_from,
             mfa :: {module(), atom(), non_neg_integer()},
             data :: term(),
             ts :: integer()}).

-record(node, {module :: module(),
               function :: atom(),
               args :: list(),
               children = [] :: [#node{}],
               result :: {return | exception, any()}}).
