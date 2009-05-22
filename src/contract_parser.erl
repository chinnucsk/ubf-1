-module(contract_parser).

%% parse contract language
%% Copyright 2002 Joe Armstrong (joe@sics.se)
%% Documentation http:://www.sics.se/~joe/ubf.html

-include("ubf_impl.hrl").

-export([parse_transform/2,
         make/0, make_lex/0, make_yecc/0, outfileExtension/0, preDefinedTypes/0, preDefinedTypesWithAttrs/0,
         tags/1, tags/2, file/1,
         parse_transform_contract/2
        ]).

-import(lists, [filter/2, map/2, member/2, foldl/3]).

parse_transform(In, Opts) ->
    %% io:format("In:~p~n   Opts: ~p~n",[In, Opts]),
    Imports = [X||{attribute,_,add_types,X} <- In],
    Out = case [X||{attribute,_,add_contract,X} <- In] of
              [File] ->
                  %% io:format("Contract: ~p ~p~n", [File, Imports]),
                  case file1(File ++ infileExtension(), Imports) of
                      {ok, Contract, Header} ->
                          HeaderFile =
                              filename:join(
                                case proplists:get_value(outdir, Opts) of undefined -> "."; OutDir -> OutDir end
                                , filename:basename(File) ++ outfileHUCExtension()
                               ),
                          %% header - hrl
                          TermHUC =
                              ["
%%%
%%% Auto-generated by contract_parser:parse_transform()
%%% Do not edit manually!
%%%
\n"]
                              ++ ["-ifndef('", File ++ ".huc", "').\n"]
                              ++ ["-define('", File ++ ".huc", "', true).\n"]
                              ++ [Header|"\n"]
                              ++ ["-endif.\n"],
                          %% io:format("Contract Header written: ~p~n", [HeaderFile]),
                          ok = file:write_file(HeaderFile, TermHUC),
                          %% io:format("Contract added:~n"),
                          parse_transform_contract(In, Contract);
                      {error, Why} ->
                          io:format("Error in contract:~p~n", [Why]),
                          exit(error)
                  end;
              [] ->
                  In
          end,
    Out.

parse_transform_contract(In, Contract) ->
    {Export, Fns} = make_code(Contract),
    In1 = merge_in_code(In, Export, Fns),
    %% lists:foreach(fun(I) -> io:format(">>~s<<~n",[erl_pp:form(I)]) end, In1),
    In1.

make_code(C) ->
    %% contract name
    F1 = {function,0,contract_name,0,
          [{clause,0,[],[],[{string,0,C#contract.name}]}]},
    %% contract vsn
    F2 = {function,0,contract_vsn,0,
          [{clause,0,[],[],[{string,0,C#contract.vsn}]}]},
    %% contract types
    TypeNames = map(fun({Type,_, _}) -> Type end, C#contract.types),
    F3 = {function,0,contract_types,0,
          [{clause,0,[],[],[erl_parse:abstract(TypeNames, 0)]}]},
    %% contract leaftypes
    LeafTypeNames = C#contract.leaftypenames,
    F4 = {function,0,contract_leaftypes,0,
          [{clause,0,[],[],[erl_parse:abstract(LeafTypeNames, 0)]}]},
    %% contract records
    RecordNames = map(fun({Record, _}) -> Record end, C#contract.records),
    F5 = {function,0,contract_records,0,
          [{clause,0,[],[],[erl_parse:abstract(RecordNames, 0)]}]},
    %% contract states
    StateNames = if C#contract.transitions =:= [] ->
                         [];
                    true ->
                         map(fun({State,_}) -> State end, C#contract.transitions)
                 end,
    F6 = {function,0,contract_states,0,
          [{clause,0,[],[],[erl_parse:abstract(StateNames, 0)]}]},
    %% contract type
    Type = map(fun({Type,Val,Str}) ->
                       {clause,1,[{atom,0,Type}],[],
                        [erl_parse:abstract({Val,Str})]}
               end, C#contract.types),
    F7 = {function,0,contract_type,1,Type},
    %% contract record
    Record = if C#contract.records =:= [] ->
                     [{clause,1,[{var,0,'_'}],[],[erl_parse:abstract([], 0)]}];
                true ->
                     map(fun({Record, Val}) ->
                                 {clause,1,[{atom,0,Record}],[],[erl_parse:abstract(Val)]}
                         end, C#contract.records)
             end,
    F8 = {function,0,contract_record,1,Record},
    %% contract state
    State = if C#contract.transitions =:= [] ->
                    [{clause,1,[{var,0,'_'}],[],[erl_parse:abstract([], 0)]}];
               true ->
                    map(fun({State,Val}) ->
                                {clause,1,[{atom,0,State}],[],[erl_parse:abstract(Val)]}
                        end, C#contract.transitions)
            end,
    F9 = {function,0,contract_state,1,State},
    %% contract anystate
    Any = if C#contract.anystate =:= [] ->
                  [];
             true ->
                  C#contract.anystate
          end,
    F10 = {function,0,contract_anystate,0,
           [{clause,0,[],[],[erl_parse:abstract(Any, 0)]}]},
    %% exports
    Exports = {attribute,0,export,
               [{contract_name,0},
                {contract_vsn,0},
                {contract_types,0},
                {contract_leaftypes,0},
                {contract_records,0},
                {contract_states,0},
                {contract_type,1},
                {contract_record,1},
                {contract_state,1},
                {contract_anystate,0}
               ]},
    %% funcs
    Funcs =  [F1,F2,F3,F4,F5,F6,F7,F8,F9,F10],
    {Exports, Funcs}.

merge_in_code([H|T], Exports, Fns)
  when element(1, H) == function orelse element(1, H) == eof ->
    [Exports,H|Fns++T];
merge_in_code([H|T], Exports, Fns) ->
    [H|merge_in_code(T, Exports, Fns)];
merge_in_code([], Exports, Fns) ->
    [Exports|Fns].

%% usage
%%    oil_parse:file(File)
%%        Converts File.ebnf -> File.xbin

make() ->
    make_lex(),
    make_yecc().

make_lex() -> leex:gen(contract, contract_lex).

make_yecc() -> yecc:yecc("contract", "contract_yecc", true).

infileExtension()  -> ".con".
outfileExtension() -> ".buc".  %% binary UBF contract
outfileHUCExtension() -> ".huc".  %% hrl UBF contract records

file(F) ->
    case {infileExtension(), filename:extension(F)} of
        {X, X} ->
            %% io:format("Parsing ~s~n", [F]),
            case file1(F) of
                {ok, Contract, _Header} ->
                    %% contract - buc
                    Enc = ubf:encode(Contract),
                    ok = file:write_file(filename:rootname(F) ++
                                         outfileExtension(),
                                         Enc),
                    Size = length(Enc),
                    Bsize = size(term_to_binary(Contract)),
                    {ok, {ubfSize,Size,bsize,Bsize}};
                Error ->
                    Error
            end;
        _ ->
            {error, bad_extension}
    end.

file1(F) ->
    file1(F,[]).

file1(F, Imports) ->
    {ok, Stream} = file:open(F, read),
    P = handle(Stream, 1, [], 0),
    file:close(Stream),
    case P of
        {ok, P1} ->
            tags(P1, Imports);
        E -> E
    end.

tags(P1) ->
    tags(P1, []).

tags(P1, Imports) ->
    case (catch pass2(P1, Imports)) of
        {'EXIT', E} ->
            {error, E};
        Contract ->
            case (catch pass4(Contract)) of
                {'EXIT', E} ->
                    {error, E};
                {Records,RecordExts} ->
                    case pass5(Contract) of
                        [] ->
                            noop;
                        UnusedTypes ->
                            if Contract#contract.transitions =/= [] orelse Contract#contract.anystate =/= [] ->
                                    exit({unused_types, UnusedTypes});
                               true ->
                                    noop
                            end
                    end,
                    %% extra leaf type names
                    LeafTypeNames = pass6(Contract),
                    %% create Records
                    AllRecords =
                        lists:keysort(1, [ {{Name,length(Fields)}, Fields} || [Name|Fields] <- Records ]
                                      ++ [ {{Name,length(Fields)+2}, ['$fields'|['$extra'|Fields]]} || [Name|Fields] <- RecordExts ]),
                    %% create Header
                    Header =
                        lists:flatten(foldl(fun({{Name,_}, Fields},L) ->
                                                    FieldStrs = [["'", atom_to_list(Field), "'"] || Field <- Fields],
                                                    FStr = join(FieldStrs, $,),
                                                    NameStr = atom_to_list(Name),
                                                    IfNdef = io_lib:format("-ifndef(~s).~n",[NameStr]),
                                                    Define = io_lib:format("-define(~s,true).~n",[NameStr]),
                                                    Record = io_lib:format("-record(~s,{~s}).~n",[ NameStr, FStr]),
                                                    EndIf = "-endif.",
                                                    L++io_lib:format("~n~s~s~s~s~n",[IfNdef,Define,Record,EndIf])
                                            end
                                            , "\n", AllRecords)),
                    {ok, Contract#contract{leaftypenames=LeafTypeNames, records=AllRecords}, Header}
            end
    end.

preDefinedTypes() -> [atom, binary, float, integer, proplist, string, term, tuple, void] ++ preDefinedTypesWithAttrs().

preDefinedTypesWithAttrs() ->
    [
     %% atom
     {atom,[ascii]}, {atom,[asciiprintable]}, {atom,[nonempty]}, {atom,[nonundefined]}
     , {atom,[ascii,nonempty]}, {atom,[ascii,nonundefined]}, {atom,[asciiprintable,nonempty]}, {atom,[asciiprintable,nonundefined]}
     , {atom,[ascii,nonempty,nonundefined]}, {atom,[asciiprintable,nonempty,nonundefined]}
     , {atom,[nonempty,nonundefined]}
     %% binary
     , {binary,[ascii]}, {binary,[asciiprintable]}, {binary,[nonempty]}
     , {binary,[ascii,nonempty]}, {binary,[asciiprintable,nonempty]}
     %% proplist
     , {proplist,[nonempty]}
     %% string
     , {string,[ascii]}, {string,[asciiprintable]}, {string,[nonempty]}
     , {string,[ascii,nonempty]}, {string,[asciiprintable,nonempty]}
     %% term
     , {term,[nonempty]}, {term,[nonundefined]}
     , {term,[nonempty,nonundefined]}
     %% tuple
     , {tuple,[nonempty]}
    ].

pass2(P, Imports) ->
    Name = require(one, name, P),
    Vsn = require(one, vsn, P),
    Types = require(one, types, P),
    Any = require(zero_or_one, anystate, P),
    Trans = require(many, transition, P),

    ImportTypes = lists:flatten(
                    [ [ begin {TDef, TTag} = Mod:contract_type(T), {T, TDef, TTag} end
                        || T <- TL ] || {Mod, TL} <- Imports ]
                   ),

    C = #contract{name=Name, vsn=Vsn, anystate=Any,
                  types=Types, transitions=Trans},
    pass3(C, ImportTypes).

require(Multiplicity, Tag, P) ->
    Vals =  [ Val || {T,Val} <- P, T == Tag ],
    case Multiplicity of
        zero_or_one ->
            case Vals of
                [] -> [];
                [V] -> V;
                _ ->
                    io:format("~p incorrectly defined~n",
                              [Tag]),
                    exit(parse)
            end;
        one ->
            case Vals of
                [V] -> V;
                _ ->
                    io:format("~p missing or incorrectly defined~n",
                              [Tag]),
                    exit(parse)
            end;
        many ->
            Vals
    end.

pass3(C1, ImportTypes) ->
    Types1 = C1#contract.types,
    Transitions = C1#contract.transitions,
    _Name = C1#contract.name,
    _Vsn = C1#contract.vsn,
    AnyState = C1#contract.anystate,

    %% io:format("Types1=~p~n",[Types1]),
    DefinedTypes1 = map(fun({I,_, _}) -> I end, Types1) ++ preDefinedTypes(),
    %% io:format("Defined types1=~p~n",[DefinedTypes1]),
    case duplicates(DefinedTypes1, []) of
        [] -> true;
        L1 -> exit({duplicated_types, L1})
    end,

    C2 = C1#contract{types=lists:usort(Types1 ++ ImportTypes)},
    Types2 = C2#contract.types,
    %% io:format("Types2=~p~n",[Types2]),
    DefinedTypes2 = map(fun({I,_, _}) -> I end, Types2) ++ preDefinedTypes(),
    %% io:format("Defined types2=~p~n",[DefinedTypes2]),
    case duplicates(DefinedTypes2, []) of
        [] -> true;
        L2 -> exit({duplicated_import_types, L2})
    end,

    %% io:format("Transitions=~p~n",[Transitions]),
    UsedTypes = extract_prims({Types2,Transitions,AnyState}, []),
    MissingTypes = UsedTypes -- DefinedTypes2,
    %% io:format("Used types=~p~n",[UsedTypes]),
    case MissingTypes of
        [] ->
            DefinedStates = [S||{S,_} <- Transitions] ++ [stop],
            %% io:format("defined states=~p~n",[DefinedStates]),
            case duplicates(DefinedStates, []) of
                [] -> true;
                L3 -> exit({duplicated_states, L3})
            end,
            %% io:format("Transitions=~p~n",[Transitions]),
            UsedStates0 = [S||{_,Rules} <- Transitions,
                              {input,_,Out} <- Rules,
                              {output,_,S} <- Out],
            UsedStates = remove_duplicates(UsedStates0),
            %% io:format("Used States=~p~n",[UsedStates]),
            MissingStates = filter(fun(I) ->
                                           not member(I, DefinedStates) end,
                                   UsedStates),
            case MissingStates of
                [] -> C2;
                _  -> exit({missing_states, MissingStates})
            end;
        _ ->
            exit({missing_types, MissingTypes})
    end.

pass4(C) ->
    Types = C#contract.types,
    Records = extract_records(Types,[]),
    RecordExts = extract_record_exts(Types,[]),
    case duplicates(Records++RecordExts, []) of
        [] -> true;
        L1 -> exit({duplicated_records, L1})
    end,
    %% io:format("Types=~p~nRecords=~p~nRecordExts=~p~n",[Types,Records,RecordExts]),
    {Records,RecordExts}.

pass5(C) ->
    Transitions = C#contract.transitions,
    AnyState = C#contract.anystate,
    %% io:format("Types=~p~n",[Types]),
    UsedTypes = extract_prims({Transitions,AnyState}, []),
    pass5(C, UsedTypes, []).

pass5(C, [], L) ->
    Types = C#contract.types,
    DefinedTypes = map(fun({I,_, _}) -> I end, Types),
    DefinedTypes -- L;
pass5(C, [H|T], L) ->
    Types = C#contract.types,
    TypeDef = [ Y || {X,Y,_Z} <- Types, X =:= H ],
    UsedTypes = [ UsedType || UsedType <- extract_prims(TypeDef, []), not member(UsedType, L) ],
    pass5(C, T ++ UsedTypes, [H|L]).

pass6(C) ->
    Transitions = C#contract.transitions,
    AnyState = C#contract.anystate,
    %% io:format("Types=~p~n",[Types]),
    RootUsedTypes = extract_prims({Transitions,AnyState}, []),
    pass6(C, RootUsedTypes, RootUsedTypes, []).

pass6(C, RootUsedTypes, [], L) ->
    Types = C#contract.types,
    DefinedTypes = map(fun({I,_, _}) -> I end, Types),
    DefinedTypes -- (RootUsedTypes -- L);
pass6(C, RootUsedTypes, [H|T], L) ->
    Types = C#contract.types,
    TypeDef = [ Y || {X,Y,_Z} <- Types, X =:= H ],
    UsedTypes = [ UsedType || UsedType <- extract_prims(TypeDef, []), member(UsedType, RootUsedTypes) ],
    pass6(C, RootUsedTypes, T, UsedTypes ++ L).

duplicates([H|T], L) ->
    case member(H, T) of
        true ->
            duplicates(T, [H|L]);
        false ->
            duplicates(T, L)
    end;
duplicates([], L) ->
    L.

extract_prims({P, X}, L)
  when P =:= prim orelse
       P =:= prim_optional orelse
       P =:= prim_nil orelse
       P =:= prim_required ->
    case member(X, L) of
        true  -> L;
        false -> [X|L]
    end;
extract_prims(T, L) when is_tuple(T) ->
    foldl(fun extract_prims/2, L, tuple_to_list(T));
extract_prims(T, L) when is_list(T) ->
    foldl(fun extract_prims/2, L, T);
extract_prims(_T, L) ->
    L.

%% ignore nested records
extract_records({record, Name, [Fields|_Values]}, L) ->
    X = [Name|extract_fields(Fields)],
    case member(X, L) of
        true  -> L;
        false -> [X|L]
    end;
extract_records(T, L) when is_tuple(T) ->
    foldl(fun extract_records/2, L, tuple_to_list(T));
extract_records(T, L) when is_list(T) ->
    foldl(fun extract_records/2, L, T);
extract_records(_T, L) ->
    L.

%% ignore nested record_exts
extract_record_exts({record_ext, Name, [Fields|_Values]}, L) ->
    X = [Name|extract_fields(Fields)],
    case member(X, L) of
        true  -> L;
        false -> [X|L]
    end;
extract_record_exts(T, L) when is_tuple(T) ->
    foldl(fun extract_record_exts/2, L, tuple_to_list(T));
extract_record_exts(T, L) when is_list(T) ->
    foldl(fun extract_record_exts/2, L, T);
extract_record_exts(_T, L) ->
    L.

extract_fields({atom,undefined}) ->
    [];
extract_fields({alt,{atom,undefined},{tuple,T}}) ->
    [Field || {atom,Field} <- T].

handle(Stream, LineNo, L, NErrors) ->
    handle1(io:requests(Stream, [{get_until,foo,contract_lex,
                                  tokens,[LineNo]}]), Stream, L, NErrors).

handle1({ok, Toks, Next}, Stream, L, Nerrs) ->
    case contract_yecc:parse(Toks) of
        {ok, Parse} ->
            %% io:format("Parse=~p~n",[Parse]),
            handle(Stream, Next, [Parse|L], Nerrs);
        {error, {Line, Mod, What}} ->
            Str = apply(Mod, format_error, [What]),
            %% io:format("Toks=~p~n",[Toks]),
            io:format("** ~w ~s~n", [Line, Str]),
            %% handle(Stream, Next, L, Nerrs+1);
            {error, 1};
        Other ->
            io:format("Bad_parse:~p\n", [Other]),
            handle(Stream, Next, L, Nerrs+1)
    end;
handle1({eof, _}, _Stream, L, 0) ->
    {ok, lists:reverse(L)};
handle1({eof, _}, _Stream, _L, N) ->
    {error, N};
handle1(What, Stream, L, Nerrs) ->
    io:format("Here:~p\n", [What]),
    handle(Stream, 1, L, Nerrs+1).

remove_duplicates([H|T]) ->
    case member(H, T) of
        true ->
            remove_duplicates(T);
        false ->
            [H|remove_duplicates(T)]
    end;
remove_duplicates([]) -> [].

join(L, Sep) ->
    lists:flatten(join2(L, Sep)).

join2([A, B|Rest], Sep) ->
    [A, Sep|join2([B|Rest], Sep)];
join2(L, _Sep) ->
    L.
