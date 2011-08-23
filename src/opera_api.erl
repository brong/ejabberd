

% Purpose (opera_api)
% Make request to opera servers and map response back to erlang structures to be used internally in ejabberd.

-module(opera_api).
-author('samuel.wejeus@opera.com').

-include("ejabberd.hrl"). 	% For macro: ?INFO_MSG
-include("mod_roster.hrl").	% For records: #roster, #rosteritem
-include("opera_api.hrl"). 	% For record: #offline_msg


% Public exported API
-export([
	get_roster/1,
	get_roster_item/2,
	delete_roster_item/2,
	set_roster_item/2,
	add_update_roster_item/2,
	wipe_roster/1,
	authenticate_user/2,
	get_vcard/1,
	set_vcard/2,
	get_domains/0,
	load_offline_messages/1,
	delete_offline_message/2,
	store_offline_message/5,
	store_chatlog/3]).



%%% ----------------------------------------------------------------------------
%%% Roster Management
%%% ----------------------------------------------------------------------------


%% @spec (User) -> [rosteritem()]
%%		User = exmpp_jid:jid()
%%		rosteritem() = mod_roster:rosteritem()
%%
%% @doc Gets the roster for a user by first preparing some json values to be used,
%% 		and then make a http request. The return value (which is a erlang:proplist)
%%		is then decoded to #rosteritem's which is the internal format for roster
%%		representation.
get_roster(User) -> 
	LJid = exmpp_jid:bare_to_list(User),
	RequestType = {"Action", "GetRoster"},
	ParamUser = {"jid", LJid},
	Request = [RequestType, ParamUser],
	case opera_http_request:exec_json_request(Request) of
		{ok, Response} ->
			case proplists:get_value("roster", Response) of
				undefined ->
					% TODO change from error.
					?DEBUG("Could not find key 'roster' in JSON response. Maybe empty roster? Response was:~n~p",[Response]),
					% We could end up here for severeal reasons.
					% For example if a users roster is empty the key roster is not definied.
					% return nothing.
					[];
				Value ->
					{array, UnFormattedRoster} = Value,
					get_roster_helper(User, UnFormattedRoster, [])
			end;
		_ -> []
	end.

		
%% @spec (User, Contact) -> rosteritem() | []
%%		User = exmpp_jid:jid()
%%		Contact = exmpp_jid:jid()
%%
%% @doc get_roster_item is the same as get_roster, but also takes an extra Contact jid,
%%		which is a contact on User's roster and gets back a single "rosteritem"
%%		rather than the entire roster list. 
get_roster_item(User, Contact) ->
	LUser = exmpp_jid:bare_to_list(User),
	LContact = exmpp_jid:bare_to_list(Contact),
	RequestType = {"Action", "GetRosterItem"},
	% The JSON API is kinda reversed here, 'cjid' stands for 'client jid'.							Or is it?
	ParamUser = {"jid", LUser},
	ParamContact = {"cjid", LContact},
	Request = [RequestType, ParamUser, ParamContact],
	case opera_http_request:exec_json_request(Request) of
		{ok, Response} ->
			case proplists:get_value("rosteritem", Response) of
				undefined ->
					% If rosteritem is undefined it simply means user have 
					% no roster items. Return nothing.
					[];
				Value ->
					% Convert to internal format. We simply use hd() so we can reuse get_roster_helper.
					hd(get_roster_helper(User, [Value],[]))
			end;
		_ -> []
	end.

%% @spec (User, mochijson:json_term(), Acc) -> [rosteritem()]
%%		User = exmpp_jid:jid()
%%		Acc = [rosteritem()] - A simple accumulator used in the recursion.
%%		rosteritem() = mod_roster:rosteritem()
%%
%% @doc Translates a mochijson representation of rosteritems to the rosteritem() format used internally in ejabberd.
get_roster_helper(User, [{struct, CurrentItem} | RosterList], Acc) ->
	% Get contact JID from proplist (the json response).
	ContactJid = exmpp_jid:parse(proplists:get_value("jid", CurrentItem)),
	ShortContactJid = jlib:short_jid(ContactJid),
	% Get contact name from proplist (the json response).
	ContactName = unicode:characters_to_binary(proplists:get_value("name", CurrentItem)),
	Subscription = get_subscription_state(proplists:get_value("subscription", CurrentItem)),
	Ask = case proplists:get_value("subscription", CurrentItem) of
				undefined -> none;
				State -> get_ask_state(State)
		  end,
	Groups = case proplists:get_value("groups", CurrentItem) of
				undefined -> [];
				{array, List} -> lists:map(fun list_to_binary/1, List);
				{_, []} -> []
			 end,
	Askmessage = list_to_binary(""), % should be ignored if Ask = none. % TODO seems like not implemented in JSON API..?
	% Build rest of structures.
	{jid, _BareJid, UserNode, UserServer, _UserResource} = User,
	USJ = {UserNode,UserServer,ShortContactJid},
	US = {UserNode,UserServer},

	RosterItem = #roster{usj=USJ, us=US, jid=ShortContactJid, name=ContactName, subscription=Subscription, ask=Ask, groups=Groups, askmessage=Askmessage},
	% Recursevily handle rest of items.
	get_roster_helper(User, RosterList, [RosterItem | Acc]);

% Basecase, last item of list (i.e the empty list)
get_roster_helper(_User, [], Data) -> Data.



%% @spec (RosterItem) -> mochijson:json_term()
%%		RosterItem = mod_roster:rosteritem()
%%
%% @doc Translates a #roster record to a JSON string.
%%		(the json api) SHOULD BE EXTENDED TO HANDLE:  
%%			Askmessage = binary()
%%      	Xs = [exmpp_xml:xmlel()]
%%			since those are a part of #roster
encode_roster_item(RosterItem) ->
	#roster{usj={_U,_S,J}, name=Name, groups=Groups, subscription=Subscription, ask=Ask} = RosterItem,
	ParamContact = {jid, jlib:jid_to_string(J)},
	ParamName = {name, Name},
	ParamSubscription = {subscription, subscription_state_to_bitmask({Subscription, Ask})},
	ParamGroups = {groups, {array, lists:map(fun erlang:binary_to_list/1, Groups)}},

	PreparedItem = {struct,[ParamContact, ParamName, ParamSubscription, ParamGroups]},
	PreparedItem.
	%mochijson:encode(PreparedItem).

%% @spec (User, RosterItem) -> rosteritem()
%%		User = exmpp_jid:jid()
%%		RosterItem = rosteritem()
%%
%% @doc Takes a #rosteritem that contains some change compared to whats stored on 
%% 		the sever and propagate that change to the server. Returns a duplicate 
%%		of the request on success.
set_roster_item(User, RosterItem) -> 
	%TODO do I need to do the checking that the contact exists or is it handled by the json API?
	LUser = exmpp_jid:bare_to_list(User),
	RequestType = {"Action", "SetRosterItem"},
	ParamUser = {"jid", LUser},
	EncodedRosterItem = encode_roster_item(RosterItem),
	ParamRosterItem = {"rosteritem", EncodedRosterItem},
	Request = [RequestType, ParamUser, ParamRosterItem],   
	case opera_http_request:exec_json_request(Request) of
		{ok, Response} ->
			case proplists:get_value("rosteritem", Response) of
				undefined ->
					% TODO change from error.
					?ERROR_MSG("Could not find key 'rosteritem' in JSON response. Response was:~n~p",[Response]),
					% return nothing.
					[];
				Value ->
					% Convert to internal format. We simply use hd() so we can reuse get_roster_helper.
					
					hd(get_roster_helper(User, [Value],[]))
			end;
		_ -> []
	end.


add_update_roster_item(User, RosterItem) ->
	LUser = exmpp_jid:bare_to_list(User),
	RequestType = {"Action", "AddUpdateRosterItem"},
	ParamUser = {"jid", LUser},
	EncodedRosterItem = encode_roster_item(RosterItem),
	ParamRosterItem = {"rosteritem", EncodedRosterItem},
	Request = [RequestType, ParamUser, ParamRosterItem],
	case opera_http_request:exec_json_request(Request) of
		{ok, Response} ->
			case proplists:get_value("rosteritem", Response) of
				undefined ->
					% TODO change from error.
					?ERROR_MSG("Could not find key 'rosteritem' in JSON response. Response was:~n~p",[Response]),
					% return nothing.
					[];
				Value ->
					% Convert to internal format. We simply use hd() so we can reuse get_roster_helper.
					hd(get_roster_helper(User, [Value],[]))
			end;
		_ -> []
	end.


%% WARNING! UNTESTED.. BUT SHOULD WORK =)
%% @spec (User, Contact) -> bool()
%%		User = exmpp_jid:jid()
%%		Contact = exmpp_jid:jid()
%%		bool() = true | false
delete_roster_item(User, Contact) ->
	LUser = exmpp_jid:bare_to_list(User),
	LContact = exmpp_jid:bare_to_list(Contact),
	RequestType = {"Action", "DeleteRosterItem"},
	ParamUser = {"jid", LUser},
	ParamContact = {"cjid", LContact},
	Request = [RequestType, ParamUser, ParamContact],
	case opera_http_request:exec_json_request(Request) of
		{ok, _Response} -> true;
		_ -> false
	end.



%% @spec (User) -> bool()
%%		User = exmpp_jid:jid()
%%		bool() = true | false
wipe_roster(User) -> 
	LJid = exmpp_jid:bare_to_list(User),
	RequestType = {"Action", "WipeRoster"},
	ParamUser = {"jid", LJid},
	Request = [RequestType, ParamUser],
	case opera_http_request:exec_json_request(Request) of
		{ok, _Response} ->
			true;
		_ -> false
	end.


%%% ----------------------------------------------------------------------------
%%% Authentication
%%% ----------------------------------------------------------------------------

%% @spec (User, Password) -> bool()
%%		User = exmpp_jid:jid()
%%		Password = string()
%%		bool() = {true, Response} | false
%%
%% @doc Authenticate a user.
authenticate_user(User, Password) ->
	%% For simple debug, make sure allways succeed.
%	true.	
	Username = exmpp_jid:bare_to_list(User),
	RequestType = {"Action", "CheckLogin"},
	ParamUser = {"username", Username},
	ParamPassword = {"password", Password},
	ParamIP = {"ip", ejabberd_sm:get_user_ip(User)},
	Request = [RequestType, ParamUser, ParamPassword, ParamIP],
	case opera_http_request:exec_json_request(Request) of
		{ok, _Response} ->
			%% Currently ignoring possible flags suppied such as 'loggin enabled'
			true;
		_ ->
			false
	end.



%%% ----------------------------------------------------------------------------
%%% Domains (Virtual Hosts)
%%% ----------------------------------------------------------------------------

%% @spec () -> some_format
%%		some_format = string()
%%
%% @doc
get_domains() -> 
	RequestType = {"Action", "GetDomains"},
	Request = [RequestType],
	case opera_http_request:exec_json_request(Request) of
		{ok, Response} ->
			case proplists:get_value("Domains", Response) of
				undefined ->
					?ERROR_MSG("Fatal Error! Could not receive list of virtual domains. Response was:~n~p",[Response]),
					[];
				{array, ListDomains} ->
					ListDomains;
				% If only a single domain is retrieved. hd() is to make sure we only send back one domain.
				Domain ->
					hd(Domain)
			end;
		_ -> []
	end.




%%% ----------------------------------------------------------------------------
%%% VCard
%%% ----------------------------------------------------------------------------

		      
%% @spec (User) -> vcard()
%%		User = exmpp_jid:jid()
%%		vcard() = ?
%%
%% @doc Retrives the VCard for a user.
get_vcard(User) ->
	LUser = exmpp_jid:bare_to_list(User),
	RequestType = {"Action", "GetVCard"},
	ParamUser = {"jid", LUser},
	Request = [RequestType, ParamUser],
	case opera_http_request:exec_json_request(Request) of
		{ok, Response} ->
			case proplists:get_value("vcard", Response) of
				undefined ->
					?DEBUG("No vcard seems to exists for user. Response was:~n~p",[Response]),
					[];
				VCard ->
					VCard
			end;
		_ -> []
	end.


%% @spec (User, VCard) -> vcard()
%%		User = exmpp_jid:jid()
%%		VCard = ?
%%		vcard() = ?
%%
%% @doc Updates the VCard for a user.
%% TODO needs to parse vcard. Should not be a problem, simple xml, check perl script.
set_vcard(User, VCard) ->
	LUser = exmpp_jid:bare_to_list(User),
	RequestType = {"Action", "SetVCard"},
	ParamUser = {"jid", LUser},
	ParamVCard = {"vcard", VCard}, % FIXME!
	Request = [RequestType, ParamUser, ParamVCard],
	case opera_http_request:exec_json_request(Request) of
		{ok, Response} ->
			case proplists:get_value("vcard", Response) of
				undefined ->
					[];
				VCard ->
					% Updated item is pushed backed to callee.
					VCard
			end;
		_ -> []
	end.
	

%%% ----------------------------------------------------------------------------
%%% Offline storage (XEP-0160)
%%% ----------------------------------------------------------------------------


                            
%[{"Status","OK"},{"content",{array,[]}}]
%% @spec (User) -> [message()] | nothing
load_offline_messages(User) ->
	LUser = exmpp_jid:bare_to_list(User),
	RequestType = {"Action", "LoadOfflineMessages"},
	ParamUser = {"jid", LUser},
	Request = [RequestType, ParamUser],
	case opera_http_request:exec_json_request(Request) of
		{ok, Response} -> 
			case proplists:get_value("content", Response) of
				undefined ->
					nothing;
				{array, MochijsonData} ->
					parse_offline_messages(MochijsonData)
			end;
		_ -> []
	end.

%% An offline message has kind of a messy syntax due to how mochijson decodes json.
%% When list of messages arrives it has the following structure:
%[{struct,[{"packet",{array,[{struct,[{"timestamp",1312376145355},
% 									  {"expire",0},
%                                     {"message", "<message/>"}]
parse_offline_messages(Messages) ->
		parse_offline_messages(Messages, []).

parse_offline_messages([], Acc) -> Acc;
parse_offline_messages([H | Messages], Acc) -> 
	{struct, Packet} = H,
	{array, Data} = proplists:get_value("packet", Packet),
	Id = proplists:get_value("id", Packet),
	{struct, DataList} = hd(Data),
	From = exmpp_jid:make(proplists:get_value("from", DataList)),
	To = exmpp_jid:make(proplists:get_value("to", DataList)),
	TimeStamp = proplists:get_value("timestamp", DataList),
	Expire = proplists:get_value("expire", DataList),
	Message = proplists:get_value("message", DataList),
	OfflineMessage = #offline_msg{from = From, to = To, id = Id, timestamp = TimeStamp, expire = Expire, packet = Message},
	parse_offline_messages(Messages, [OfflineMessage | Acc]).



store_offline_message(From, To, TimeStamp, Expire, Message) ->
	LFrom = exmpp_jid:bare_to_list(From),
	LTo = exmpp_jid:bare_to_list(To),
	RequestType = {"Action", "StoreOfflineMessage"},
	ParamUser = {"jid", LTo},
	PrepPacket = prepare_offline_message(LFrom, LTo, TimeStamp, Expire, Message),
	ParamPacket = {"packet", PrepPacket},
	
	Request = [RequestType, ParamUser, ParamPacket],
	case opera_http_request:exec_json_request(Request) of
		{ok, _Response} -> nothing;
		_ -> nothing
	end.

%% Usage of 'struct' format is so that mochijson can encode it.
prepare_offline_message(LFrom, LTo, TimeStamp, Expire, Message) ->
	PrepFrom = {"from", LFrom},
	PrepTo = {"to", LTo},
	PrepTimeStamp = {"timestamp", TimeStamp},
	PrepExpire = {"expire", Expire},
	PrepMessage = {"message", Message},
	{array, [{struct,[PrepFrom, PrepTo, PrepTimeStamp, PrepExpire, PrepMessage]}]}.



delete_offline_message(User, Id) ->
	LUser = exmpp_jid:bare_to_list(User),
	RequestType = {"Action", "DeleteOfflineMessage"},
	ParamUser = {"jid", LUser},
	ParamId = {"id", Id},
	Request = [RequestType, ParamUser, ParamId],
	case opera_http_request:exec_json_request(Request) of
		{ok, Response} -> 
			case proplists:get_value("content", Response) of
				undefined ->
					nothing;
				{array, MessagesBlob} -> 
					MessagesBlob;
				_ -> nothing
			end;
		_ -> []
	end.



%%% ----------------------------------------------------------------------------
%%% Chatlog
%%% ----------------------------------------------------------------------------

%% @spec (User, Contact, Messages) -> ok | aborted
%%		User = string()
%%		Contact = string()
%%		Messages = [string()]
store_chatlog(User, Contact, Messages) ->
	Items = lists:map(fun({From, To, Timestamp, Message}) -> 
						SubParamFrom = {"from", From},
						SubParamTo = {"to", To},
						SubParamTime = {"time", Timestamp},
						SubParamText = {"text", Message},
						{struct,[SubParamFrom, SubParamTo, SubParamTime, SubParamText]}
					end, Messages),
	RequestType = {"Action", "ChatLog"},
	ParamUser = {"jid", User},
	ParamContact = {"tojid", Contact},
	{_From, _To, InitialConversationTimestamp, _Message} = hd(Messages),
	ParamFirst = {"first", InitialConversationTimestamp},
	ParamItems = {"items", {array,Items}},
	Request = [RequestType, ParamUser, ParamContact, ParamFirst, ParamItems],
	case opera_http_request:exec_json_request(Request) of
		{ok, _Response} -> ok;
		_ -> aborted
	end.

%{array, [{struct,[PrepFrom, PrepTo, PrepTimeStamp, PrepExpire, PrepMessage]}]}.


%%% ----------------------------------------------------------------------------
%%% TEMPORARY HELPERS, SHOULD BE CHANGED ONCE THE JSON API IS UPDATED.
%%% ----------------------------------------------------------------------------

%# The nine valid subscription states from the spec: (little endian..)
%#                         TO  FROM  PIN  POUT
%#   None                  -   -     -    -
%#   None+PendOut          -   -     -    X  8
%#   None+PendIn           -   -     X    -  4
%#   None+PendIn+PendOut   -   -     X    X  12
%#   To                    X   -     -    -  1
%#   To+PendIn             X   -     X    -  5
%#   From                  -   X     -    -  2
%#   From+PendOut          -   X     -    X  10
%#   Both                  X   X     -    -  3
get_subscription_state(Bitmask) ->
	case Bitmask of
		"1" -> to;
		"2" -> from;
		"3" -> both;
        "4" -> none;
		"5" -> to;
		"8" -> none;
		"10" -> from;
		"12" -> none;
		_ -> none
	end.
get_ask_state(Bitmask) ->
	case Bitmask of
		"1" -> none;
		"2" -> none;
		"3" -> none;
        "4" -> in;
		"5" -> in;
		"8" -> out;
		"10" -> out;
		"12" -> both;
		_ -> none
	end.
subscription_state_to_bitmask({Subscription, Ask}) ->
	case {Subscription, Ask} of
		{both, _} -> "3";
		{from,out} -> "10";
		{from,_} -> "2";
		{to,to} -> "5";
		{to,_} -> "1";
		{none,both} -> "12";
		{none,in} -> "4";
		{none,out} -> "8";
		{none,_} -> "0"
	end.






