%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2015, 2600Hz INC
%%% @doc
%%%
%%% @end
%%% @contributors
%%%   Luis Azedo
%%%-------------------------------------------------------------------
-module(knm_managed).

-behaviour(knm_gen_carrier).

-export([find_numbers/3]).
-export([acquire_number/1]).
-export([disconnect_number/1]).
-export([is_number_billable/1]).
-export([should_lookup_cnam/0]).

-export([generate_numbers/3]).
-export([import_numbers/2]).

-include("knm.hrl").

-define(KZ_MANAGED, <<"numbers%2Fmanaged">>).
-define(MANAGED_VIEW_FILE, <<"views/managed.json">>).

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Query the local system for a quanity of available numbers
%% in a rate center
%% @end
%%--------------------------------------------------------------------
-spec find_numbers(ne_binary(), pos_integer(), kz_proplist()) ->
                          {'ok', knm_number:knm_numbers()} |
                          {'error', any()}.
find_numbers(<<"+", _/binary>>=Number, Quantity, Opts) ->
    AccountId = props:get_value(<<"Account-ID">>, Opts),
    find_numbers_in_account(Number, Quantity, AccountId);
find_numbers(Number, Quantity, Opts) ->
    find_numbers(<<"+",Number/binary>>, Quantity, Opts).

-spec find_numbers_in_account(ne_binary(), pos_integer(), api_binary()) ->
                                     {'ok', knm_number:knm_numbers()} |
                                     {'error', any()}.
find_numbers_in_account(Number, Quantity, AccountId) ->
    case do_find_numbers_in_account(Number, Quantity, AccountId) of
        {'error', 'not_available'}=Error ->
            case kz_services:find_reseller_id(AccountId) of
                AccountId -> Error;
                ResellerId ->
                    find_numbers_in_account(Number, Quantity, ResellerId)
            end;
        Result -> Result
    end.

-spec do_find_numbers_in_account(ne_binary(), pos_integer(), api_binary()) ->
                                        {'ok', knm_number:knm_numbers()} |
                                        {'error', any()}.
do_find_numbers_in_account(Number, Quantity, AccountId) ->
    ViewOptions = [{'startkey', [AccountId, ?NUMBER_STATE_AVAILABLE, Number]}
                   ,{'endkey', [AccountId, ?NUMBER_STATE_AVAILABLE, <<Number/binary, "\ufff0">>]}
                   ,{'limit', Quantity}
                   ,'include_docs'
                  ],
    case kz_datamgr:get_results(?KZ_MANAGED, <<"numbers/status">>, ViewOptions) of
        {'ok', []} ->
            lager:debug("found no available managed numbers for account ~p", [AccountId]),
            {'error', 'not_available'};
        {'ok', JObjs} ->
            lager:debug("found available managed numbers for account ~s", [AccountId]),
            {'ok', format_numbers_resp(AccountId, JObjs)};
        {'error', _R}=E ->
            lager:debug("failed to lookup available managed numbers: ~p", [_R]),
            E
    end.

-spec format_numbers_resp(ne_binary(), kz_json:objects()) -> knm_number:knm_numbers().
format_numbers_resp(AccountId, JObjs) ->
    [format_number_resp(AccountId, JObj) || JObj <- JObjs].

-spec format_number_resp(ne_binary(), kz_json:object()) -> knm_number:knm_number().
format_number_resp(AccountId, JObj) ->
    Doc = kz_json:get_value(<<"doc">>, JObj),
    {'ok', PhoneNumber} =
        knm_phone_number:newly_found(kz_doc:id(Doc), ?MODULE, AccountId, Doc),
    knm_number:set_phone_number(knm_number:new(), PhoneNumber).

-spec is_number_billable(knm_number:knm_number()) -> boolean().
is_number_billable(_Number) -> 'false'.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Acquire a given number from the carrier
%% @end
%%--------------------------------------------------------------------
-spec acquire_number(knm_number:knm_number()) ->
                            knm_number:knm_number().
acquire_number(Number) ->
    PhoneNumber = knm_number:phone_number(Number),
    Num = knm_phone_number:number(PhoneNumber),
    AssignTo = knm_phone_number:assigned_to(PhoneNumber),
    State = knm_phone_number:state(PhoneNumber),
    lager:debug("acquiring number ~s in ~s provider", [Num, ?MODULE]),
    update_doc(Number, [{?PVT_STATE, State}
                       ,{?PVT_ASSIGNED_TO, AssignTo}
                       ]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Release a number from the routing table
%% @end
%%--------------------------------------------------------------------
-spec disconnect_number(knm_number:knm_number()) ->
                               knm_number:knm_number().
disconnect_number(Number) ->
    Num = knm_phone_number:number(knm_number:phone_number(Number)),
    lager:debug("disconnect number ~s in managed provider", [Num]),
    update_doc(Number, [{?PVT_STATE, ?NUMBER_STATE_RELEASED}
                       ,{?PVT_ASSIGNED_TO, <<>>}
                       ]).

-spec generate_numbers(ne_binary(), pos_integer(), non_neg_integer()) -> 'ok'.
generate_numbers(_AccountId, _Number, 0) -> 'ok';
generate_numbers(AccountId, Number, Quantity)
  when Quantity > 0
       andalso is_integer(Number)
       andalso is_integer(Quantity) ->
    {'ok', _JObj} = save_doc(AccountId, kz_util:to_binary(Number)),
    generate_numbers(AccountId, Number+1, Quantity-1).

-spec import_numbers(ne_binary(), ne_binaries()) -> kz_json:object().
import_numbers(_AccountId, Numbers) ->
    import_numbers(_AccountId, Numbers, kz_json:new()).

-spec import_numbers(ne_binary(), ne_binaries(), kz_json:object()) -> kz_json:object().
import_numbers(_AccountId, [], JObj) -> JObj;
import_numbers(AccountId, [Number | Numbers], JObj) ->
    NewJObj =
        case save_doc(AccountId, Number) of
            {'ok', _Doc} ->
                kz_json:set_value([<<"success">>, Number], kz_json:new(), JObj);
            {'error', Reason} ->
                Error = kz_json:from_list([{<<"reason">>, Reason}
                                          ,{<<"message">>, <<"error adding number to DB">>}
                                          ]),
                kz_json:set_value([<<"errors">>, Number], Error, JObj)
        end,
    import_numbers(AccountId, Numbers, NewJObj).

-spec save_doc(ne_binary(), ne_binary()) -> {'ok', kz_json:object()} |
                                            {'error', any()}.
save_doc(AccountId, Number) ->
    JObj = kz_json:from_list([{<<"_id">>, knm_converters:normalize(Number)}
                              ,{<<"pvt_account_id">>, AccountId}
                              ,{?PVT_STATE, ?NUMBER_STATE_AVAILABLE}
                              ,{?PVT_TYPE, <<"number">>}
                             ]),
    save_doc(JObj).

-spec save_doc(kz_json:object()) -> {'ok', kz_json:object()} |
                                    {'error', any()}.
save_doc(JObj) ->
    case kz_datamgr:save_doc(?KZ_MANAGED, JObj) of
        {'error', 'not_found'} ->
            'true' = kz_datamgr:db_create(?KZ_MANAGED),
            {'ok', _View} = kz_datamgr:revise_doc_from_file(?KZ_MANAGED, kz_util:to_atom(?APP_NAME), ?MANAGED_VIEW_FILE),
            save_doc(JObj);
        Result -> Result
    end.

-spec update_doc(knm_number:knm_number(), kz_proplist()) ->
                        knm_number:knm_number().
update_doc(Number, UpdateProps) ->
    PhoneNumber = knm_number:phone_number(Number),
    Doc = knm_phone_number:doc(PhoneNumber),
    case kz_datamgr:update_doc(?KZ_MANAGED, kz_doc:id(Doc), UpdateProps) of
        {'error', Reason} ->
            knm_errors:database_error(Reason, PhoneNumber);
        {'ok', UpdatedDoc} ->
            knm_number:set_phone_number(
              Number
              ,knm_phone_number:from_json(UpdatedDoc)
             )
    end.

-spec should_lookup_cnam() -> 'true'.
should_lookup_cnam() -> 'true'.
