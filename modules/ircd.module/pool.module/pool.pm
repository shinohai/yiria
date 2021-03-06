# Copyright (c) 2009-14, Mitchell Cooper
#
# @name:            "ircd::pool"
# @package:         "pool"
# @description:     "manage IRC objects"
# @version:         ircd->VERSION
# @no_bless:        1
# @preserve_sym:    1
#
# @author.name:     "Mitchell Cooper"
# @author.website:  "https://github.com/cooper"
#
package pool;

use warnings;
use strict;
use 5.010;
use parent 'Evented::Object';

use Scalar::Util qw(weaken blessed);
use utils qw(v set_v notice conf ref_to_list);

our ($api, $mod, $me);

# create a pool.
sub new {
    return bless { user_i => 'a' }, shift;
}

###################
### CONNECTIONS ###
###################

# create a connection.
# note: if ever adding new things to any new() subs,
# keep in mind that those will obviously not be present in
# existing objects after an IRCd reload.
sub new_connection {
    my ($pool, %opts) = @_;
    my $connection = connection->new($opts{stream}) or return;
    
    # store it by stream.
    $pool->{connections}{ $opts{stream} } = $connection;
    
    # weakly reference to the pool.
    weaken($connection->{pool} = $pool);
    
    # become an event listener.
    $connection->add_listener($pool, 'connection');

    # fire connection creation event.
    $connection->fire_event('new');

    # update total connection count
    my $connection_num = v('connection_count') + 1;
    set_v(connection_count => $connection_num);

    # update maximum connection count.
    if (scalar keys %{ $pool->{connections} } > v('max_connection_count')) {
        set_v(max_connection_count => scalar keys %{ $pool->{connections} });
    }
    
    notice(new_connection => $connection->{ip}, $connection_num);
    return $connection;
}

# find a connection by its stream.
sub lookup_connection {
    my ($pool, $stream) = @_;
    return $pool->{connections}{$stream};
}

# delete a connection.
sub delete_connection {
    my ($pool, $connection, $reason) = @_;
    notice(connection_terminated =>
        $connection->{ip},
        $connection->{type} ? $connection->{type}->full : 'unregistered',
        $reason // 'Unknown reason'
    );
    
    # forget it.
    delete $pool->{connections}{ $connection->{stream} };
    delete $connection->{pool};
    
    return 1;
}

sub connections { values %{ shift->{connections} } }

###############
### SERVERS ###
###############

# create a server.
sub new_server {
    my $pool = shift;
    
    # if the first arg is blessed, it's a server.
    # this is used only for the local server.
    my $server = shift;
    if (blessed $server) {
        my %opts = @_;
        @$server{keys %opts} = values %opts;
    }
    
    # not blessed, just options.
    else {
        unshift @_, $server;
        $server = server->new(@_) or return;
    }
    
    # store it by ID and name.
    $pool->{servers}{ $server->{sid} } =
    $pool->{server_names}{ lc $server->{name} } = $server;
    
    # weakly reference to the pool.
    weaken($server->{pool} = $pool);
    weaken($server->{parent});
    
    # become an event listener.
    $server->add_listener($pool, 'server');
    $server->fire_event('new');
    
    notice(new_server =>
        $server->{name},
        $server->{sid},
        $server->{ircd},
        $server->{proto},
        $server->{desc},
        $server->{parent}{name}
    );
    return $server;
}

# find a server.
sub lookup_server {
    my ($pool, $sid) = @_;
    return $pool->{servers}{$sid};
}

# find a server by its name.
sub lookup_server_name {
    my ($pool, $sname) = @_;
    
    # $sid format
    if ($sname =~ m/^\$(\d+)$/) {
        return $pool->lookup_server($1);
    }
    
    return $pool->{server_names}{ lc $sname };
}

# find any number of servers by mask.
sub lookup_server_mask {
    my ($pool, $mask) = @_;
    
    # $sid format
    if ($mask =~ m/^\$(\d+)$/) {
        return $pool->lookup_server($1);
    }
    
    my @matches;
    foreach my $server (sort { $a->{name} cmp $b->{name} } $pool->servers) {
        next unless utils::irc_match($server->{name}, $mask);
        
        # if we are returning a single server and if
        # the local server matches, return it.
        return $server if !wantarray && $server->is_local;
        
        # otherwise, just add to the list.
        push @matches, $server;
        
    }
    return wantarray ? @matches : $matches[0];
}

# delete a server.
sub delete_server {
    my ($pool, $server) = @_;
    
    # forget it.
    delete $server->{pool};
    delete $pool->{servers}{ $server->{sid} };
    delete $pool->{server_names}{ lc $server->{name} };
    
    L("deleted server $$server{name}");
    return 1;
}

sub     servers { grep { !$_->{fake} } shift->all_servers }
sub all_servers { values %{ shift->{servers} }            }

#############
### USERS ###
#############

# create a user.
sub new_user {
    my ($pool, %opts) = @_;
    
    # no server provided; default to this server.
    weaken($opts{server} ||= $me);
    
    # no UID provided; generate one.
    # no nick specified; use UID.
    $opts{uid}  //= $me->{sid}.$pool->{user_i}++;
    $opts{nick} //= $opts{uid};
    
    delete $opts{stream};
    my $user = user->new(%opts) or return;
    
    # store it by ID and nick.
    $pool->{users}{ $opts{uid} } =
    $pool->{nicks}{ lc $opts{nick} } = $user;
    
    # weakly reference to the pool.
    weaken($user->{pool} = $pool);
    
    # become an event listener.
    $user->add_listener($pool, 'user');
    $user->fire_event('new');

    # add the user to the server.
    push @{ $opts{server}{users} }, $user;
    
    # update max local and global user counts.
    my $max_l = v('max_local_user_count');
    my $max_g = v('max_global_user_count');
    my $c_l   = scalar grep { $_->is_local } values %{ $pool->{users} };
    my $c_g   = scalar values %{ $pool->{users} };
    set_v(max_local_user_count  => $c_l) if $c_l > $max_l;
    set_v(max_global_user_count => $c_g) if $c_g > $max_g;

    notice(new_user => $user->notice_info, $user->{real}, $user->{server}{name});
    return $user;
}

# find a user.
sub lookup_user {
    my ($pool, $uid) = @_;
    return $pool->{users}{$uid};
}

# find a user by his nick.
sub lookup_user_nick {
    my ($pool, $nick) = @_;
    my $user_maybe = $pool->{nicks}{ lc $nick };
    blessed $user_maybe && $user_maybe->isa('user') or return;
    return $user_maybe;
}

sub reserve_nick {
    my ($pool, $nick, $obj) = @_;
    weaken($pool->{nicks}{ lc $nick } = $obj);
    return 1;
}

sub release_nick {
    my ($pool, $nick) = @_;
    return if $pool->lookup_user_nick($nick);
    delete $pool->{nicks}{ lc $nick };
}

sub nick_in_use {
    my ($pool, $nick) = @_;
    return $pool->{nicks}{ lc $nick };
}

# delete a user.
sub delete_user {
    my ($pool, $user) = @_;

    # remove from server.
    # this isn't a very efficient way to do this.
    my $users = $user->{server}{users};
    @$users = grep { $_ != $user } @$users;
    
    # forget it.
    delete $user->{pool};
    delete $pool->{users}{ $user->{uid} };
    delete $pool->{nicks}{ lc $user->{nick} };
    
    L("deleted user $$user{nick}");
    return 1;
}

# change a user's nickname.
sub change_user_nick {
    my ($pool, $user, $newnick) = @_;
    
    # make sure it doesn't exist first.
    my $in_use = $pool->nick_in_use($newnick);
    if ($in_use && $in_use != $user) {
        L("attempted to change nicks to a nickname that already exists! $newnick");
        return;
    }
    
    # it does not exist.
    delete $pool->{nicks}{ lc $user->{nick} };
    $pool->{nicks}{ lc $newnick } = $user;
    
    return 1;
}

# actual_users = real users, both local and remote
# global_users = all users which are propogated, including fake ones
# all_users    = all user objects, including those which are not propogated
# local_users  = real local users

sub local_users  {   grep  { $_->is_local && !$_->{fake}    } shift->all_users  }
sub actual_users {   grep  { !$_->{fake}                    } shift->all_users  }
sub global_users {   grep  { !$_->{fake_local}              } shift->all_users  }
sub all_users    { values %{ shift->{users}                 }                   }

################
### CHANNELS ###
################

# create a channel.
sub new_channel {
    my ($pool, %opts) = @_;
    
    # make sure it doesn't exist already.
    if ($pool->{channels}{ lc $opts{name} }) {
        L("attempted to create channel that already exists: $opts{name}");
        return;
    }
    
    my $channel = channel->new(%opts) or return;
    
    # store it by name.
    $pool->{channels}{ lc $opts{name} } = $channel;
    
    # weakly reference to the pool.
    weaken($channel->{pool} = $pool);
    
    # become an event listener.
    $channel->add_listener($pool, 'channel');
    
    L("new channel $opts{name} at $opts{time}");
    return $channel;
}

# find a channel by its name.
sub lookup_channel {
    my ($pool, $name) = @_;
    return $pool->{channels}{ lc $name };
}

sub lookup_or_create_channel {
    my ($pool, $name, $time) = @_;
    
    # if the channel exists, just join.
    my $channel = $pool->lookup_channel($name);
    return $channel if $channel;
    
    # otherwise create a new one.
    $channel = $pool->new_channel(
        name => $name,
        time => $time || time
    );
    
    # second return value is whether it's a new channel.
    return wantarray ? ($channel, 1) : $channel;
    
}

# returns true if the two passed users have a channel in common.
# well actually it returns the first match found, but that's usually useless.
sub channel_in_common {
    my ($pool, $user1, $user2) = @_;
    foreach my $channel (values %{ $pool->{channels} }) {
        return $channel if $channel->has_user($user1) && $channel->has_user($user2);
    }
    return;
}

# delete a channel.
sub delete_channel {
    my ($pool, $channel) = @_;
    
    # forget it.
    delete $channel->{pool};
    delete $pool->{channels}{ lc $channel->name };
    
    L("deleted channel $$channel{name}");
    return 1;
}

sub channels { values %{ shift->{channels} } }

#############################
### USER COMMAND HANDLERS ###
#############################

# register command handlers
sub register_user_handler {
    my ($pool, $source, $command) = (shift, shift, uc shift);

    # does it already exist?
    if ($pool->{user_commands}{$command}) {
        L("attempted to register $command which already exists");
        return;
    }

    my ($params, $ref, $desc, $fantasy) = @_;

    # ensure that it is CODE
    if (ref $ref ne 'CODE') {
        L("not a CODE reference for $command");
        return;
    }

    # success
    $pool->{user_commands}{$command} = {
        code    => $ref,
        params  => $params,
        source  => $source,
        desc    => $desc,
        fantasy => $fantasy
    };
    
    #L("$source registered $command: $desc");
    return 1;
}

# unregister handler
sub delete_user_handler {
    my ($pool, $command) = (shift, uc shift);
    #L("deleting handler $command");
    delete $pool->{user_commands}{$command};
}

sub user_handlers {
    my ($pool, $command) = (shift, uc shift);
    return $pool->{user_commands}{$command} // ();
}

#####################
### USER NUMERICS ###
#####################

# register user numeric
# $allowed = allowed for connections; only checked if $fmt is a coderef.
sub register_numeric {
    my ($pool, $source, $numeric, $num, $fmt, $allowed) = @_;

    # does it already exist?
    if (exists $pool->{numerics}{$numeric}) {
        L("attempted to register $numeric which already exists");
        return;
    }

    $pool->{numerics}{$numeric} = [$num, $fmt, $allowed];
    #L("$source registered $numeric $num");
    return 1;
}

# unregister user numeric
sub delete_numeric {
    my ($pool, $source, $numeric) = @_;

    # does it exist?
    if (!exists $pool->{numerics}{$numeric}) {
        L("attempted to delete $numeric which does not exists");
        return;
    }

    delete $pool->{numerics}{$numeric};
    #L("$source deleted $numeric");
    
    return 1;
}

sub numeric {
    my ($pool, $numeric) = @_;
    return $pool->{numerics}{$numeric};
}


####################
### OPER NOTICES ###
####################

# register notice
sub register_notice {
    my ($pool, $source, $notice, $fmt) = @_;

    # does it already exist?
    if (exists $pool->{oper_notices}{$notice}) {
        L("attempted to register $notice which already exists");
        return;
    }

    $pool->{oper_notices}{$notice} = $fmt;
    #L("$source registered oper notice '$notice'");
    return 1;
}

# unregister notice
sub delete_notice {
    my ($pool, $source, $notice) = @_;

    # does it exist?
    if (!exists $pool->{oper_notices}{$notice}) {
        L("attempted to delete oper notice '$notice' which does not exists");
        return;
    }

    delete $pool->{oper_notices}{$notice};
    #L("$source deleted oper notice '$notice'");
    
    return 1;
}

# send out a notice.
sub fire_oper_notice {
    my ($pool, $notice, $amnt) = (shift, lc shift, 0);
    my $message = $pool->{oper_notices}{$notice} or return;
    
    # code reference.
    if (ref $message eq 'CODE') {
        $message = $message->(@_);
    }
    
    # formatter.
    else {
        $message = sprintf $message, @_;
    }

    (my $pretty = ucfirst $notice) =~ s/_/ /g;
    
    # send to users with this notice flag.
    foreach my $user ($pool->actual_users) {
        next unless blessed $user; # during destruction.
        next unless $user->is_mode('ircop');
        next unless $user->has_notice($notice);
        
        $user->server_notice('Notice', ucfirst($pretty).': '.$message);
        $amnt++;
    }
    
    return wantarray ? ($amnt, $pretty, $message) : $amnt;
}

###############################
### SERVER COMMAND HANDLERS ###
###############################


# register command handlers
# ($source, $command, $callback, $forward)
sub register_server_handler {
    my ($pool, $source, $command) = (shift, shift, uc shift);

    # does it already exist?
    if (exists $pool->{server_commands}{$command}) {
        L("attempted to register $command which already exists");
        return;
    }

    # ensure that it is CODE
    my $ref = shift;
    if (ref $ref ne 'CODE') {
        L("not a CODE reference for $command");
        return;
    }

    #success
    $pool->{server_commands}{$command} = {
        code    => $ref,
        source  => $source,
        forward => shift
    };
    
    #L("$source registered $command");
    return 1;
}

# unregister
sub delete_server_handler {
    my ($pool, $command) = (shift, uc shift);
    #L("deleting handler $command");
    delete $pool->{server_commands}{$command};
}

sub server_handlers {
    my ($pool, $command) = (shift, uc shift);
    return $pool->{server_commands}{$command} // ();
}

################################
### OUTGOING SERVER COMMANDS ###
################################

# register an outgoing server command.
sub register_outgoing_handler {
    my ($pool, $source, $command, $ref, $proto) = @_;
    $command = uc $command;

    # does it already exist?
    if (exists $pool->{outgoing_commands}{$proto}{$command}) {
        L("attempted to register $command which already exists");
        return;
    }

    # ensure that it is CODE.
    if (ref $ref ne 'CODE' && ref $ref ne 'ARRAY') {
        L("not a CODE reference for $command");
        return;
    }

    # success.
    $pool->{outgoing_commands}{$proto}{$command} = {
        code    => ref $ref eq 'ARRAY' ? $ref : [ $ref ],
        source  => $source
    };
    
    #L("$source registered $command");
    return 1;
}

# delete an outgoing server command.
sub delete_outgoing_handler {
    my ($pool, $command, $proto) = (shift, uc shift, shift);
    #L("deleting handler $command");
    delete $pool->{outgoing_commands}{$proto}{$command};
}

# fire an outgoing server command for a single server.
sub fire_command {
    my ($pool, $server, $command, @args) = (shift, shift, uc shift, @_);
    return if $server->{fake};
    return if $server == $me;
    
    # command does not exist.
    my $proto = $server->{link_type} or return;
    my $cmd   = $pool->{outgoing_commands}{$proto}{$command};
    return unless $cmd;

    # send to one server.
    my @code  = ref_to_list($cmd->{code});
    my @lines = map { $_->($server, @args) } @code;
    $server->send(@lines);

    return 1;
}

# fire an outgoing server command for all servers.
sub fire_command_all {
    my ($pool, $command, @args) = (shift, uc shift, @_);

    # send to all children.
    foreach ($me->children) {

        # don't send to servers who haven't received my burst.
        next unless $_->{i_sent_burst};
        
        $_->fire_command($command => @args);
    }

    return 1;
}

########################
### USER MODE BLOCKS ###
########################

# register a user mode block.
sub register_user_mode_block {
    my ($pool, $name, $what, $code) = @_;

    # not a code reference.
    if (ref $code ne 'CODE') {
        L((caller)[0]." tried to register a block to $name that isn't CODE.");
        return;
    }

    # already exists from this source.
    if (exists $pool->{user_modes}{$name}{$what}) {
        L((caller)[0]." tried to register $what to $name which is already registered");
        return;
    }

    $pool->{user_modes}{$name}{$what} = $code;
    #L("registered $name from $what");
    return 1;
}

# delete a user mode block.
sub delete_user_mode_block {
    my ($pool, $name, $what) = @_;
    if (my $hash = $pool->{user_modes}{$name}) {
        delete $hash->{$what};
        delete $pool->{user_modes}{$name} unless scalar keys %$hash;
        #L("deleting user mode block for $name: $what");
        return 1;
    }
    return;
}

# fire a user mode.
sub fire_user_mode {
    my ($pool, $user, $state, $name) = @_;
    my $amount = 0;
    
    # nothing to do.
    return $amount unless exists $pool->{user_modes}{$name};

    # call each block.
    foreach my $block (values %{ $pool->{user_modes}{$name} }) {
        return unless $block->($user, $state);
        $amount++;
    }

    # all returned true
    return $amount;
}

sub user_mode_string {
    my @names = keys %{ shift->{user_modes} || {} };
    my @letters;
    foreach my $name (@names) {
        my $letter = $me->umode_letter($name) or next;
        push @letters, $letter;
    }
    return join '', sort @letters;
}

###########################
### CHANNEL MODE BLOCKS ###
###########################

# types:
#   normal          (0)
#   parameter       (1)
#   parameter_set   (2)
#   list            (3)
#   status          (4)

# register a block check to a mode.
sub register_channel_mode_block {
    my ($pool, $name, $what, $code) = @_;
    
    # not a code reference.
    if (ref $code ne 'CODE') {
        L((caller)[0]." tried to register a block to $name that isn't CODE.");
        return;
    }
    
    # it exists already from this source.
    if (exists $pool->{channel_modes}{$name}{$what}) {
        L((caller)[0]." tried to register $name to $what which is already registered");
        return;
    }
    
    #L("registered $name from $what");
    $pool->{channel_modes}{$name}{$what} = $code;
    return 1;
}

# delete a channel mode block.
sub delete_channel_mode_block {
    my ($pool, $name, $what) = @_;
    if (my $hash = $pool->{channel_modes}{$name}) {
        delete $hash->{$what};
        delete $pool->{channel_modes}{$name} unless scalar keys %$hash;
        return 1;
    }
    return;
}

# fire a channel mode.
sub fire_channel_mode {
    my ($pool, $channel, $name, $this) = @_;
    my $amount = 0;
    
    # nothing to do.
    return $amount unless $pool->{channel_modes}{$name};

    # fire each block.
    foreach my $block (values %{ $pool->{channel_modes}{$name} }) {
        return (undef, $this) unless $block->($channel, $this);
        $amount++;
    }
    
    return ($amount, $this);
}

sub channel_mode_string {
    my @names = keys %{ shift->{channel_modes} || {} };
    my @letters;
    foreach my $name (@names) {
        my $letter = $me->cmode_letter($name) or next;
        push @letters, $letter;
    }
    return join '', sort @letters;
}

#####################
### USER MATCHERS ###
#####################

sub user_match {
    my ($pool, $user, @list) = @_;
    my $e = $pool->fire_event(user_match => $user, @list);
    return $e->{matched};
}

####################
### CAPABILITIES ###
####################

# register capability
sub register_cap {
    my ($pool, $source, $cap, %opts) = @_;
    $cap = lc $cap;

    # does it already exist?
    if (exists $pool->{capabilities}{$cap}) {
        L("attempted to register '$cap' which already exists");
        return;
    }

    $pool->{capabilities}{$cap} = { name => $cap, %opts };
    return 1;
}

# we have a capability available.
sub has_cap { shift->{capabilities}{ lc shift } }

# unregister capability
sub delete_cap {
    my ($pool, $source, $cap) = @_;
    $cap = lc $cap;

    # does it exist?
    if (!exists $pool->{capabilities}{$cap}) {
        L("attempted to delete '$cap' which does not exists");
        return;
    }

    delete $pool->{capabilities}{$cap};
    return 1;
}

sub capabilities { keys %{ shift->{capabilities} || {} } }

$mod