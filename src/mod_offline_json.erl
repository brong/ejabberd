
%% mod_offline_json
%% Handles offline messages, as a friendly token i also included a start for some basic functions
%% to handle limits on offline storage. Its not done yet some one else has to finish them.

-module(mod_offline_json).
-author('samuel.wejeus@opera.com').

-behaviour(gen_mod).

-include_lib("exmpp/include/exmpp.hrl").
-include("ejabberd.hrl").
-include("opera_api.hrl"). % For record #offline_msg

-export([start/2, stop/1,
	 store_packet/3,
	 pop_offline_messages/3,
	 get_sm_features/5]).

start(Host, Opts) when is_list(Host) ->
    start(list_to_binary(Host), Opts);
start(_HostB, _Opts) ->
    ejabberd_hooks:add(offline_message_hook, global, ?MODULE, store_packet, 50),
    ejabberd_hooks:add(resend_offline_messages_hook, global, ?MODULE, pop_offline_messages, 50),
    ejabberd_hooks:add(disco_sm_features, global, ?MODULE, get_sm_features, 50),
    ejabberd_hooks:add(disco_local_features, global, ?MODULE, get_sm_features, 50).
    %% Hooks for future usage of message quotas -------------------------------------------------------
    %AccessMaxOfflineMsgs = gen_mod:get_opt(access_max_user_messages, Opts, max_user_offline_messages),
    %register(gen_mod:get_module_proc(HostB, ?PROCNAME), spawn(?MODULE, loop, [AccessMaxOfflineMsgs])).

stop(_Host) ->
    ejabberd_hooks:delete(offline_message_hook, global, ?MODULE, store_packet, 50),
    ejabberd_hooks:delete(resend_offline_messages_hook, global, ?MODULE, pop_offline_messages, 50),
    ejabberd_hooks:delete(disco_sm_features, global, ?MODULE, get_sm_features, 50),
    ejabberd_hooks:delete(disco_local_features, global, ?MODULE, get_sm_features, 50).
    %% Hooks for future usage of message quotas -------------------------------------------------------
    %Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    %exit(whereis(Proc), stop),
    %{wait, Proc}.
    
    

store_packet(From, To, Message) ->
    Type = exmpp_stanza:get_type(Message),
    if (Type /= <<"error">>) and (Type /= <<"groupchat">>) and (Type /= <<"headline">>) ->
	    case mod_offline:check_event_chatstates(From, To, Message) of
			true ->
				TimeStamp = mod_offline:make_timestamp(),
				Expire = mod_offline:find_x_expire(TimeStamp, Message#xmlel.children),
				MessageB = exmpp_xml:document_to_binary(Message),
				
				opera_api:store_offline_message(From, To, TimeStamp, Expire, MessageB),
				stop;
			_ ->
				ok
	    end;
	true ->
	    ok
    end.


%% @spec(Ls::list(), User::binary(), Server::binary()) -> list()
pop_offline_messages(Ls, User, Server) ->
    try
		UserJid = exmpp_jid:make(User,Server),
		Messages = opera_api:load_offline_messages(UserJid),
		case Messages of % Messages = [#offline_msg]
			[] -> 
				Ls;
			MsgList ->
				TS = mod_offline:make_timestamp(),
				Ls ++ lists:map(
					fun(R) ->

						Packet = store_to_stanza(R#offline_msg.packet),
						TimeXml = mod_offline:timestamp_to_xml(R#offline_msg.timestamp, Server),
						TimeXml91 = mod_offline:timestamp_to_xml(R#offline_msg.timestamp),

						%% We assume that once messages has been serialized and routed to user they are also
						%% delivered. We then delete old ones from server. This breaks whats defined in XEP-0013
						%% but according to XEP-0160 is sort of ok.
						opera_api:delete_offline_message(UserJid, R#offline_msg.id),
						
						%% Route message to user.
						{route,R#offline_msg.from,R#offline_msg.to,exmpp_xml:append_children(Packet,[TimeXml, TimeXml91])}
					end, 
					lists:filter(
					  fun(R) ->
						case R#offline_msg.expire of
							0 ->
							true;
							TimeStamp ->
							TS < TimeStamp
						end
					  end,
					  lists:keysort(#offline_msg.timestamp, MsgList)))	
		end
    catch
		_ ->
			Ls
    end.
    
stanza_to_store(Stanza) ->
    exmpp_xml:document_to_binary(Stanza).
store_to_stanza(StoreBinary) -> 
    [Xml] = exmpp_xml:parse_document(unicode:characters_to_binary(StoreBinary)),
    Xml.

%% Used by service discovery to let client know that we offer offline support.
get_sm_features(Acc, _From, _To, <<>>, _Lang) ->
    Feats = case Acc of
		{result, I} -> I;
		_ -> []
	    end,
    {result, Feats ++ [?NS_MSGOFFLINE]};
get_sm_features(_Acc, _From, _To, ?NS_MSGOFFLINE, _Lang) ->
    %% override all lesser features...
    {result, []};
get_sm_features(Acc, _From, _To, _Node, _Lang) ->
    Acc.




%% -----------------------------------------------------------------------------
%% Below are basic functions needed for future implementation of message quotas.
%% -----------------------------------------------------------------------------

%% default value for the maximum number of user messages (NOTE: message limit currently not implemented).
% -define(MAX_USER_MESSAGES, infinity).

%% Function copied from ejabberd_sm.erl:
%get_max_user_messages(AccessRule, LUser, Host) ->
%    case acl:match_rule(Host, AccessRule, exmpp_jid:make(LUser, Host, "")) of
%		Max when is_integer(Max) -> Max;
%		infinity -> infinity;
%		_ -> ?MAX_USER_MESSAGES
%    end.

%% Warn senders that their messages have been discarded:
%discard_warn_sender(Msgs) ->
%    lists:foreach(
%      fun(#offline_msg{from=From, to=To, packet=PacketStored}) ->
%	      Packet = store_to_stanza(PacketStored),
%	      ErrText = "Your contact offline message queue is full. The message has been discarded.",
%	      Error = exmpp_stanza:error(Packet#xmlel.ns, 'resource-constraint',
%		{"en", ErrText}),
%	      Err = exmpp_stanza:reply_with_error(Packet, Error),
%	      ejabberd_router:route(
%		To,
%		From, Err)
%     end, Msgs).





