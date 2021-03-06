# Copyright (c) 2014, matthew
#
# Created on mattbook
# Sun Jun 29 14:49:55 EDT 2014
# Limit.pm
#
# @name:            'Channel::Limit'
# @package:         'M::Channel::Limit'
# @description:     'adds channel user limit mode'
#
# @depends.modules: ['Base::ChannelModes', 'Base::UserNumerics']
#
# @author.name:     'Matthew Barksdale'
# @author.website:  'https://github.com/mattwb65'
#
package M::Channel::Limit;

use warnings;
use strict;
use 5.010;
use Scalar::Util 'looks_like_number';

our ($api, $mod, $pool);
my $MAX = ~0 >> 1;

sub init {
    
    # register limit mode block.
    $mod->register_channel_mode_block(
        name => 'limit',
        code => \&cmode_limit
    ) or return;
    
    # register ERR_CHANNELISFULL
    $mod->register_user_numeric(
        name   => 'ERR_CHANNELISFULL',
        number => 471,
        format => '%s :Channel is full'
    ) or return;
    
    # Hook on the can_join event to prevent joining a channel that is full
    $pool->on('user.can_join' => \&on_user_can_join, with_eo => 1, name => 'has.limit');
    
    return 1;
}

sub cmode_limit {
    my ($channel, $mode) = @_;
    $mode->{has_basic_status} or return;
    
    # always allow unsetting.
    return 1 if !$mode->{state};
    
    # not a number.
    return if !looks_like_number($mode->{param});
    
    # determine the value.
    $mode->{param} = int $mode->{param};
    $mode->{param} = $MAX if $mode->{param} > $MAX;
    
    # it's negative or nan.
    return if $mode->{param} <= 0;
    return if $mode->{param} eq 'nan';
    
    return 1;
}

sub on_user_can_join {
    my ($user, $event, $channel) = @_;
    return unless $channel->is_mode('limit');
    return if 1 + scalar $channel->users <= $channel->mode_parameter('limit');
    $user->numeric(ERR_CHANNELISFULL => $channel->name) unless $event->{silent_errors};
    $event->stop('channel_full');
}



$mod

