

%% The packet construct used in connection with serialization/deserialization of offline messages.
-record(offline_msg, {id,timestamp, expire, from, to, packet}).
