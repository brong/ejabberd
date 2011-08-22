
-module(opera_aux).
-compile(export_all).

-include_lib("exmpp/include/exmpp.hrl").
-include("mod_roster.hrl").
-include("ejabberd.hrl").


%%% ----------------------------------------------------------------------------
%%% Duplicates some code from mod_roster.erl that is not exported. 
%%% Some calls have been changed to include namespace: mod_roster_json
%%% ----------------------------------------------------------------------------


%% @spec (Item, Attrs) -> New_Item
%%     Item = rosteritem()
%%     Attrs = [exmpp_xml:xmlnsattribute()]
%%     New_Item = rosteritem()

process_item_attrs(Item, [#xmlattr{name = Attr, value = Val} | Attrs]) ->
    case Attr of
	<<"name">> ->
	    process_item_attrs(Item#roster{name = Val}, Attrs);
	<<"subscription">> ->
	    case Val of
		<<"remove">> ->
		    process_item_attrs(Item#roster{subscription = remove},
				       Attrs);
		_ ->
		    process_item_attrs(Item, Attrs)
	    end;
	<<"ask">> ->
	    process_item_attrs(Item, Attrs);
	_ ->
	    process_item_attrs(Item, Attrs)
    end;
process_item_attrs(Item, []) ->
    Item.


%% @spec (Item, Els) -> New_Item
%%     Item = rosteritem()
%%     Els = [exmpp_xml:xmlel()]
%%     New_Item = rosteritem()
process_item_els(Item, [#xmlel{ns = NS, name = Name} = El | Els]) ->
    case Name of
	'group' ->
	    Groups = [exmpp_xml:get_cdata(El) | Item#roster.groups],
	    process_item_els(Item#roster{groups = Groups}, Els);
	_ ->
	    if
		NS == ?NS_JABBER_CLIENT; NS == ?NS_JABBER_SERVER ->
		    process_item_els(Item, Els);
		true ->
		    XEls = [El | Item#roster.xs],
		    process_item_els(Item#roster{xs = XEls}, Els)
	    end
    end;
process_item_els(Item, [_ | Els]) ->
    process_item_els(Item, Els);
process_item_els(Item, []) ->
    Item.


%% @spec (User, Server, From, Item) -> term()
%%     User = binary()
%%     Server = binary()
%%     From = exmpp_jid:jid()
%%     Item = rosteritem()

push_item(User, Server, From, Item)
  when is_binary(User), is_binary(Server), ?IS_JID(From) ->
    {U, S, R2} = Item#roster.jid,
    %% the ?XMLATTR macro will convert 'undefined' to <<"undefined">> .. so here we use <<>> for bare jids.
    R = case R2 of 
        undefined -> <<>>;
        _ -> R2
    end,
    ejabberd_sm:route(exmpp_jid:make(),
		      exmpp_jid:make(User, Server),
		      #xmlel{name = 'broadcast', ns = roster_item, attrs =
		       [?XMLATTR(<<"u">>, U),
		        ?XMLATTR(<<"s">>, S),
		        ?XMLATTR(<<"r">>, R),
		        ?XMLATTR(<<"subs">>, Item#roster.subscription)]}),

    case mod_roster_json:roster_versioning_enabled(Server) of
    	true ->
		push_item_version(Server, User, From, Item, mod_roster_json:roster_version(Server, User));
	false ->
	    lists:foreach(fun(Resource) ->
 			  push_item(User, Server, Resource, From, Item)
		  end, ejabberd_sm:get_user_resources(User, Server))
    end.

%% @spec (User, Server, Resource, From, Item) -> term()
%%     User = binary()
%%     Server = binary()
%%     Resource = binary()
%%     From = exmpp_jid:jid()
%%     Item = rosteritem()

% TODO: don't push to those who didn't load roster
push_item(User, Server, Resource, From, Item) ->
    push_item(User, Server, Resource, From, Item, not_found).

push_item(User, Server, Resource, From, Item, RosterVersion)
  when is_binary(User), is_binary(Server), is_binary(Resource),
  ?IS_JID(From) ->
    ExtraAttrs = case RosterVersion of
	not_found -> [];
	_ -> [?XMLATTR(<<"ver">>, RosterVersion)]
    end,
    Request = #xmlel{ns = ?NS_ROSTER, name = 'query',
      attrs = ExtraAttrs,
      children = [mod_roster:item_to_xml(Item)]},
    ResIQ = exmpp_iq:set(?NS_JABBER_CLIENT, Request,
      "push" ++ randoms:get_string()),
    ejabberd_router:route(
      From,
      exmpp_jid:make(User, Server, Resource),
      ResIQ).

%% @doc Roster push, calculate and include the version attribute.
%% TODO: don't push to those who didn't load roster
push_item_version(Server, User, From, Item, RosterVersion)  ->
    lists:foreach(fun(Resource) ->
			  push_item(User, Server, Resource, From, Item, RosterVersion)
		end, ejabberd_sm:get_user_resources(User, Server)).



%% in_state_change(Subscription, Pending, Type) -> NewState
%% NewState = none | {NewSubscription, NewPending}
-ifdef(ROSTER_GATEWAY_WORKAROUND).
-define(NNSD, {to, none}).
-define(NISD, {to, in}).
-else.
-define(NNSD, none).
-define(NISD, none).
-endif.

in_state_change(none, none, subscribe)    -> {none, in};
in_state_change(none, none, subscribed)   -> ?NNSD;
in_state_change(none, none, unsubscribe)  -> none;
in_state_change(none, none, unsubscribed) -> none;
in_state_change(none, out,  subscribe)    -> {none, both};
in_state_change(none, out,  subscribed)   -> {to, none};
in_state_change(none, out,  unsubscribe)  -> none;
in_state_change(none, out,  unsubscribed) -> {none, none};
in_state_change(none, in,   subscribe)    -> none;
in_state_change(none, in,   subscribed)   -> ?NISD;
in_state_change(none, in,   unsubscribe)  -> {none, none};
in_state_change(none, in,   unsubscribed) -> none;
in_state_change(none, both, subscribe)    -> none;
in_state_change(none, both, subscribed)   -> {to, in};
in_state_change(none, both, unsubscribe)  -> {none, out};
in_state_change(none, both, unsubscribed) -> {none, in};
in_state_change(to,   none, subscribe)    -> {to, in};
in_state_change(to,   none, subscribed)   -> none;
in_state_change(to,   none, unsubscribe)  -> none;
in_state_change(to,   none, unsubscribed) -> {none, none};
in_state_change(to,   in,   subscribe)    -> none;
in_state_change(to,   in,   subscribed)   -> none;
in_state_change(to,   in,   unsubscribe)  -> {to, none};
in_state_change(to,   in,   unsubscribed) -> {none, in};
in_state_change(from, none, subscribe)    -> none;
in_state_change(from, none, subscribed)   -> {both, none};
in_state_change(from, none, unsubscribe)  -> {none, none};
in_state_change(from, none, unsubscribed) -> none;
in_state_change(from, out,  subscribe)    -> none;
in_state_change(from, out,  subscribed)   -> {both, none};
in_state_change(from, out,  unsubscribe)  -> {none, out};
in_state_change(from, out,  unsubscribed) -> {from, none};
in_state_change(both, none, subscribe)    -> none;
in_state_change(both, none, subscribed)   -> none;
in_state_change(both, none, unsubscribe)  -> {to, none};
in_state_change(both, none, unsubscribed) -> {from, none}.

out_state_change(none, none, subscribe)    -> {none, out};
out_state_change(none, none, subscribed)   -> none;
out_state_change(none, none, unsubscribe)  -> none;
out_state_change(none, none, unsubscribed) -> none;
out_state_change(none, out,  subscribe)    -> {none, out}; %% We need to resend query (RFC3921, section 9.2)
out_state_change(none, out,  subscribed)   -> none;
out_state_change(none, out,  unsubscribe)  -> {none, none};
out_state_change(none, out,  unsubscribed) -> none;
out_state_change(none, in,   subscribe)    -> {none, both};
out_state_change(none, in,   subscribed)   -> {from, none};
out_state_change(none, in,   unsubscribe)  -> none;
out_state_change(none, in,   unsubscribed) -> {none, none};
out_state_change(none, both, subscribe)    -> none;
out_state_change(none, both, subscribed)   -> {from, out};
out_state_change(none, both, unsubscribe)  -> {none, in};
out_state_change(none, both, unsubscribed) -> {none, out};
out_state_change(to,   none, subscribe)    -> none;
out_state_change(to,   none, subscribed)   -> {both, none};
out_state_change(to,   none, unsubscribe)  -> {none, none};
out_state_change(to,   none, unsubscribed) -> none;
out_state_change(to,   in,   subscribe)    -> none;
out_state_change(to,   in,   subscribed)   -> {both, none};
out_state_change(to,   in,   unsubscribe)  -> {none, in};
out_state_change(to,   in,   unsubscribed) -> {to, none};
out_state_change(from, none, subscribe)    -> {from, out};
out_state_change(from, none, subscribed)   -> none;
out_state_change(from, none, unsubscribe)  -> none;
out_state_change(from, none, unsubscribed) -> {none, none};
out_state_change(from, out,  subscribe)    -> none;
out_state_change(from, out,  subscribed)   -> none;
out_state_change(from, out,  unsubscribe)  -> {from, none};
out_state_change(from, out,  unsubscribed) -> {none, out};
out_state_change(both, none, subscribe)    -> none;
out_state_change(both, none, subscribed)   -> none;
out_state_change(both, none, unsubscribe)  -> {from, none};
out_state_change(both, none, unsubscribed) -> {to, none}.

in_auto_reply(from, none, subscribe)    -> subscribed;
in_auto_reply(from, out,  subscribe)    -> subscribed;
in_auto_reply(both, none, subscribe)    -> subscribed;
in_auto_reply(none, in,   unsubscribe)  -> unsubscribed;
in_auto_reply(none, both, unsubscribe)  -> unsubscribed;
in_auto_reply(to,   in,   unsubscribe)  -> unsubscribed;
in_auto_reply(from, none, unsubscribe)  -> unsubscribed;
in_auto_reply(from, out,  unsubscribe)  -> unsubscribed;
in_auto_reply(both, none, unsubscribe)  -> unsubscribed;
in_auto_reply(_,    _,    _)  ->           none.
