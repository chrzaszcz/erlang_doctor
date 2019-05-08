-record(tr, {index :: pos_integer(),
             pid :: pid(),
             event :: call | return_from | exception_from,
             mfa :: {atom(), atom(), non_neg_integer()},
             data :: term(),
             ts :: integer()}).
