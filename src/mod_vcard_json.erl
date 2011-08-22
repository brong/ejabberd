

-module(mod_vcard_json).
-author('alexey@process-one.net').

-behaviour(gen_mod).

-include_lib("exmpp/include/exmpp.hrl").
-include("ejabberd.hrl").

-export([start/2, stop/1,
	 process_local_iq/3,
	 process_sm_iq/3]).


-define(PROCNAME, ejabberd_mod_vcard_json).
-define(JUD_MATCHES, 30).

start(Host, Opts) when is_list(Host) ->
    start(list_to_binary(Host), Opts);
start(_HostB, Opts) ->
    IQDisc = gen_mod:get_opt(iqdisc, Opts, one_queue),
    gen_iq_handler:add_iq_handler(ejabberd_local, global, ?NS_VCARD, ?MODULE, process_local_iq, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_sm, global, ?NS_VCARD, ?MODULE, process_sm_iq, IQDisc).




stop(_Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, global, ?NS_VCARD),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, global, ?NS_VCARD).


% needed to make local call.
process_local_iq(From, To, IQ) ->
	mod_vcard:process_local_iq(From, To, IQ).

% needed to make local call.
process_sm_iq(_From, To, #iq{type = get} = IQ_Rec) ->
    LUser = exmpp_jid:prep_node(To),
    LServer = exmpp_jid:prep_domain(To),
    case get_vcard(LUser, LServer) of
	{vcard, VCard} ->
	    exmpp_iq:result(IQ_Rec, VCard);
	novcard ->
	    exmpp_iq:result(IQ_Rec)
    end;
% needed to make local call.    
process_sm_iq(From, _To, #iq{type = set, payload = Request} = IQ_Rec) ->
    User = exmpp_jid:node(From),
    Server = exmpp_jid:prep_domain(From),
    ServerS = exmpp_jid:prep_domain_as_list(From),
    case ?IS_MY_HOST(ServerS) of
	true ->
	    set_vcard(User, Server, Request),
	    exmpp_iq:result(IQ_Rec);
	false ->
	    exmpp_iq:error(IQ_Rec, 'not-allowed')
    end.

%% @spec (User::binary(), Host::binary()) -> {vcard, xmlel()} | novcard
get_vcard(User, Host) ->
    UserJid = exmpp_jid:make(User, Host),
    case opera_api:get_vcard(UserJid) of
		[] ->
		    novcard;
		XML_VCard ->
		    {vcard, hd(exmpp_xml:parse_document(XML_VCard))}
    end.


set_vcard(User, Server, VCARD) ->
	opera_api:set_vcard(exmpp_jid:make(User,Server),exmpp_xml:document_to_list(VCARD)),
	ejabberd_hooks:run(vcard_set, Server, [User, Server, VCARD]).
  






