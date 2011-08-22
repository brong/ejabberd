
-module(ejabberd_auth_json).
-author('samuel.wejeus@opera.com').

-include("ejabberd.hrl").

%% External exports
-export([start/1,
	 stop/1,
	 set_password/3,
	 check_password/3,
	 check_password/5,
	 try_register/3,
	 dirty_get_registered_users/0,
	 get_vh_registered_users/1,
	 get_vh_registered_users_number/1,
	 get_password/2,
	 get_password_s/2,
	 is_user_exists/2,
	 remove_user/2,
	 remove_user/3,
	 plain_password_required/0
	]).


%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

%% @spec (Host) -> ok
%%     Host = string()
start(Host) ->
	?DEBUG("Starting JSON authentication service on host: \"~s\"",[Host]),
	ok.

stop(Host) ->
	?DEBUG("Shutting down JSON authentication service on host: \"~s\"",[Host]),
    ok.

%% @spec () -> bool()
plain_password_required() ->
    true.

%% @spec (User, Server, Password) -> bool()
%%     User = string() = JID Node
%%     Server = string() = JID Domain
%%     Password = string()
check_password(User, Server, Password) ->
	Jid = exmpp_jid:make(User, Server),
	opera_api:authenticate_user(Jid, Password).

%% @spec (User, Server, Password, Digest, DigestGen) -> bool()
%%     User = string()
%%     Server = string()
%%     Password = string()
%%     Digest = string()
%%     DigestGen = function()
check_password(User, Server, Password, _Digest, _DigestGen) ->
	check_password(User, Server, Password).
	
	
	
	

%%%----------------------------------------------------------------------
%%% Forbidden or unused API calls.
%%%----------------------------------------------------------------------

%% @spec () -> [{LUser, LServer}]
%%     LUser = string()
%%     LServer = string()
%% @doc Get all registered users in Mnesia.
dirty_get_registered_users() ->
    [{"dummy_user", "dev.null"}].

%% @spec (Server) -> [{LUser, LServer}]
%%     Server = string()
%%     LUser = string()
%%     LServer = string()
get_vh_registered_users(_Server) ->
	[{"dummy_user", "dev.null"}].

%% @spec (Server) -> Users_Number
%%     Server = string()
%%     Users_Number = integer()
get_vh_registered_users_number(_Server) ->
	0.
	
%% @spec (User, Server) -> Password | false
%%     User = string()
%%     Server = string()
%%     Password = string()
get_password(_User, _Server) ->
	("no_password").

%% @spec (User, Server) -> Password | nil()
%%     User = string()
%%     Server = string()
%%     Password = string()
get_password_s(_User, _Server) ->
	("no_password").

%% @spec (User, Server) -> true | false | {error, Error}
%%     User = string()
%%     Server = string()
is_user_exists(_User, _Server) ->
	true.

%% @spec (User, Server, Password) -> ok | {error, invalid_jid}
%%     User = string()
%%     Server = string()
%%     Password = string()
%%	   Change of password thru XMPP client is not allowed. Just returns ok on whatever.
set_password(_User, _Server, _Password) ->
	ok.
	
%% @spec (User, Server) -> ok
%%     User = string()
%%     Server = string()
%% @doc Remove user.
%% Note: it returns ok even if there was some problem removing the user.
remove_user(_User, _Server) ->
	ok.
	
%% @spec (User, Server, Password) -> {atomic, ok} | {atomic, exists} | {error, invalid_jid} | {aborted, Reason}
%%     User = string()
%%     Server = string()
%%     Password = string()
try_register(_User, _Server, _Password) ->
	{aborted, "json auth does not allow inband registration."}.
	
%% @spec (User, Server, Password) -> ok | not_exists | not_allowed | bad_request
%%     User = string()
%%     Server = string()
%%     Password = string()
%% @doc Remove user if the provided password is correct.
remove_user(_User, _Server, _Password) ->
	not_allowed.



