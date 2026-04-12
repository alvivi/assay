-module(graded_ffi).
-export([shell_exec/1]).

shell_exec(Command) ->
    Result = os:cmd(unicode:characters_to_list(Command)),
    unicode:characters_to_binary(Result).
