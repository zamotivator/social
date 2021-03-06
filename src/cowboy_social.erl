%%
%% @doc Handler for social login via OAuth2 providers.
%%

-module(cowboy_social).
-author('Vladimir Dronnikov <dronnikov@gmail.com>').

% -behaviour(cowboy_rest_handler).
-export([
    init/3,
    terminate/3,
    rest_init/2,
    allowed_methods/2,
    content_types_provided/2
  ]).

-export([
    get_html/2,
    get_json/2
  ]).

-record(state, {
    action,
    options
  }).

init(_Transport, Req, Opts) ->
  {Action, Req2} = cowboy_req:binding(action, Req, <<"login">>),
  {upgrade, protocol, cowboy_rest, Req2, #state{
      action = Action,
      options = Opts
    }}.

terminate(_Reason, _Req, _State) ->
  ok.

rest_init(Req, State = #state{options = O}) ->
  % compose full redirect URI
  {Req3, O3} = case key(callback_uri, O) of
    << "http://", _/binary >> ->
      {Req, O};
    << "https://", _/binary >> ->
      {Req, O};
    Relative ->
      {Headers, Req2} = cowboy_req:headers(Req),
      % NB: we use X-Scheme custom header to honor proxies
      O2 = keyreplace(callback_uri, O,
          cowboy_request:make_uri(
              key(<<"x-scheme">>, Headers, <<"http">>),
              key(<<"host">>, Headers),
              Relative)),
      {Req2, O2}
  end,
  {ok, Req3, State#state{options = O3}}.

allowed_methods(Req, State) ->
  {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
  {[
    {{<<"text">>, <<"html">>, []}, get_html},
    {{<<"application">>, <<"json">>, []}, get_json}
  ], Req, State}.

get_html(Req, State) ->
  case get_json(Req, State) of
    {Result, Req2, State2} when is_binary(Result) ->
      {ok, Req3} = cowboy_req:reply(200, [], <<
        "<script>",
        "window.atoken=", Result/binary, ";",
        "if(window.atoken&&window.opener){",
          "window.opener.atoken=window.atoken;"
          "window.close();",
        "}",
        "</script>"
        >>, Req2),
      {halt, Req3, State2};
    {html, Result, Req2, State2} ->
      {Result, Req2, State2};
    Else ->
      Else
  end.

get_json(Req, State) ->
  case action(Req, State) of
    {ok, Result, Req2} ->
      {jsx:encode(Result), Req2, State};
    {error, Error, Req2} ->
      {jsx:encode([{error, Error}]), Req2, State};
    {html, Result, Req2} ->
      {html, Result, Req2, State};
    Else ->
      Else
  end.

%%
%% User agent initiates the flow.
%%
action(Req, #state{action = <<"login">>, options = O}) ->
  {Type, Req2} = cowboy_req:qs_val(<<"response_type">>, Req, <<"code">>),
  {Opaque, Req3} = cowboy_req:qs_val(<<"state">>, Req2, <<>>),
  % redirect to provider authorization page
  % Mod = binary_to_atom(<< "cowboy_social_", Provider/binary >>, latin1),
  % {ok, Req4} = cowboy_req:reply(302, [
  %     {<<"location">>, Mod:authorize(Opts)}
  %   ], <<>>, Req3),
  % {halt, Req4, State};
  redirect(key(authorize_uri, O), [
      {client_id, key(client_id, O)},
      {redirect_uri, key(callback_uri, O)},
      {response_type, Type},
      {scope, key(scope, O)},
      {state, Opaque}
    ], Req3);

%%
%% Provider redirects back to client with authorization code.
%% Exchange authorization code for access token.
%%
action(Req, State = #state{action = <<"callback">>}) ->
  case cowboy_req:qs_val(<<"error">>, Req) of
    {undefined, Req2} ->
      check_code(Req2, State);
    {Error, Req2} ->
      {error, Error, Req2}
  end.

check_code(Req, State = #state{options = O}) ->
  case cowboy_req:qs_val(<<"code">>, Req) of
    {undefined, Req2} ->
      check_token(Req2, State);
    {Code, Req2} ->
      %% Provider redirected back to the client with authorization code.
      %% Exchange authorization code for access token.
      post(key(token_uri, O), [
          {code, Code},
          {client_id, key(client_id, O)},
          {client_secret, key(client_secret, O)},
          {redirect_uri, key(callback_uri, O)},
          {grant_type, <<"authorization_code">>}
        ], Req2)
  end.

check_token(Req, State) ->
  case cowboy_req:qs_val(<<"access_token">>, Req) of
    {undefined, Req2} ->
      implicit_flow_stage2(Req2, State);
    {Token, Req2} ->
      {TokenType, Req3} = cowboy_req:qs_val(
          <<"token_type">>, Req2, <<"bearer">>),
      {ok, [
          {access_token, Token},
          {token_type, TokenType}
        ], Req3}
  end.

%%
%% Provider redirected back to the client with access token in URI fragment.
%% Fragment is stored in UA, this handler should provide UA with a script
%% to extract access token.
%%
implicit_flow_stage2(Req, _State) ->
  {html, <<
      "<!--script>",
      % "if(window.opener){window.location=window.location.href.replace('#','?')}",
      "window.location.replace(window.location.href.replace('#','?'))",
      "</script-->"
    >>, Req}.

%%
%%------------------------------------------------------------------------------
%% Helpers
%%------------------------------------------------------------------------------
%%

redirect(Uri, Params, Req) ->
  {ok, Req2} = cowboy_req:reply(302, [
      {<<"location">>,
          << Uri/binary, $?, (cowboy_request:urlencode(Params))/binary >>}
    ], <<>>, Req),
  {halt, Req2, undefined}.

post(Url, Params, Req) ->
  try cowboy_request:post_for_json(Url, Params) of
    {ok, Auth} ->
      case lists:keyfind(<<"error">>, 1, Auth) of
        false ->
          {ok, [
              {access_token, key(<<"access_token">>, Auth)},
              {token_type, key(<<"token_type">>, Auth, <<"bearer">>)}
            ], Req};
        {_, Error} ->
          {error, Error, Req}
      end;
    _Else ->
      {error, <<"authorization_error">>, Req}
  catch _:_ ->
    {error, <<"server_error">>, Req}
  end.

key(Key, List) ->
  {_, Value} = lists:keyfind(Key, 1, List),
  Value.

key(Key, List, Def) ->
  case lists:keyfind(Key, 1, List) of
    {_, Value} -> Value;
    _ -> Def
  end.

keyreplace(Key, List, Value) ->
  lists:keyreplace(Key, 1, List, {Key, Value}).
