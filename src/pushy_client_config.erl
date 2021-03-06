%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92-*-
%% ex: ts=4 sw=4 et
%% @author James Casey <james@opscode.com>

%% @doc  Retrieve configuration from a pushy server via HTTP
%% @copyright Copyright 2012 Chef Software, Inc. All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License. You may obtain
%% a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied. See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%

-module(pushy_client_config).

-export([
         get_config/6
        ]).

-include("pushy_messaging.hrl").
-include("pushy_client.hrl").

-spec get_config(OrgName :: binary(),
                 NodeName :: binary(),
                 CreatorName :: binary(),
                 PrivateKey ::  #'RSAPrivateKey'{},
                 Hostname :: binary(),
                 Port :: integer()) -> #pushy_client_config{}.
%% @doc retrieve the configuration for a pushy server from the REST config
%% endpoint
get_config(OrgName, NodeName, CreatorName, PrivateKey, Hostname, Port) ->
    Path = path(OrgName, NodeName),
    Headers =  chef_authn:sign_request(PrivateKey, <<"">>, CreatorName,
                                       <<"GET">>, now, Path),
    FullHeaders = [{"Accept", "application/json"}|Headers],
    Url = construct_url(Hostname, Port, Path),
    case ibrowse:send_req(Url, FullHeaders, get) of
        {ok, Code, ResponseHeaders, ResponseBody} ->
            ok = check_http_response(Code, ResponseHeaders, ResponseBody),
            parse_json_response(PrivateKey, ResponseBody);
        {error, Reason} ->
            throw({error, Reason})
    end.

-spec parse_json_response(PrivateKey::any(), Body::string()) -> #pushy_client_config{}.
%% @doc Parse the configuration response body and return the heartbeat
%% and command channel addresses along with the public key
%% for the server.
%%
%% We convert the zeromq addresses to lists since it doesn't support
%% binary endpoints and the heartbeat interval to an integer
parse_json_response(PrivateKey, Body) ->
    EJson = jiffy:decode(Body),
    HeartbeatAddress = ej:get({"push_jobs", "heartbeat", "out_addr"}, EJson),
    CommandAddress = ej:get({"push_jobs", "heartbeat", "command_addr"}, EJson),
    Interval = ej:get({"push_jobs", "heartbeat", "interval"}, EJson),
    {SessionMethod, SessionKey} = extract_session_key(PrivateKey, EJson),
    {ok, PublicKey} = rsa_public_key(ej:get({"public_key"}, EJson)),
    #pushy_client_config{heartbeat_address = binary_to_list(HeartbeatAddress),
                         heartbeat_interval = round(Interval*1000),
                         command_address = binary_to_list(CommandAddress),
                         session_key = SessionKey,
                         session_method = SessionMethod,
                         server_public_key = PublicKey}.

extract_session_key(PrivateKey, EJson) ->
    case ej:get({"encoded_session_key"}, EJson) of
        undefined ->
            extract_plain_session_key(EJson);
        _ ->
            extract_enc_session_key(PrivateKey, EJson)
    end.

extract_plain_session_key(EJson) ->
    SessionKey = base64:decode(ej:get({"session_key", "key"}, EJson)),
    SessionMethod = pushy_messaging:method_to_atom(ej:get({"session_key", "method"}, EJson)),
    {SessionMethod, SessionKey}.

extract_enc_session_key(PrivateKey, EJson) ->
    EncodedSessionKey = ej:get({"encoded_session_key", "key"}, EJson),
    SessionMethod = pushy_messaging:method_to_atom(ej:get({"encoded_session_key", "method"}, EJson)),
    SessionKey = public_key:decrypt_private(base64:decode(EncodedSessionKey), PrivateKey),
    {SessionMethod, SessionKey}.


rsa_public_key(BinKey) ->
    case chef_authn:extract_public_or_private_key(BinKey) of
        {error, bad_key} ->
            lager:error("Can't decode Public Key ~s~n", [BinKey]),
            {error, bad_key};
         Key when is_tuple(Key) ->
            {ok, Key}
    end.




%% @doc Check the code of the HTTP response and throw error if non-2XX
%%
check_http_response(Code, Headers, Body) ->
    case Code of
        "2" ++ _Digits ->
            ok;
        "3" ++ _Digits ->
            throw({error, {redirection, {Code, Headers, Body}}});
        "404" ->
            throw({error, {not_found, {Code, Headers, Body}}});
        "4" ++ _Digits ->
            throw({error, {client_error, {Code, Headers, Body}}});
        "5" ++ _Digits ->
            throw({error, {server_error, {Code, Headers, Body}}})
    end.


-spec construct_url(Hostname :: binary(),
                    Port :: integer(),
                    Path :: binary()) -> list().
construct_url(Hostname, Port, Path) ->
    lists:flatten(io_lib:format("http://~s:~w/~s", [Hostname, Port, Path])).

-spec path(OrgName :: binary(),
           NodeName :: binary()) -> binary().
path(OrgName, NodeName) ->
    list_to_binary(io_lib:format("/organizations/~s/pushy/config/~s", [ OrgName, NodeName])).
