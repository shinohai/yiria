# Copyright (c) 2014, Mitchell Cooper
#
# @name:            "Base::Matchers"
# @version:         ircd->VERSION
# @package:         "M::Base::Matchers"
#
# @author.name:     "Mitchell Cooper"
# @author.website:  "https://github.com/cooper"
#
package M::Base::Matchers;

use warnings;
use strict;
use 5.010;

my ($api, $mod);

sub init {
    
    # register methods.
    $mod->register_module_method('register_matcher') or return;
    
    # module unload event.
    $api->on(unload_module => \&unload_module) or return;
    
    return 1;
}

sub register_matcher {
    my ($mod, %opts) = @_;
    
    # register the event.
    $::pool->register_event(
        user_match => $opts{code},
        %opts
    ) or return;
    
    # TODO: log.
    
    $mod->list_store_add('matchers', $opts{name});    
    return $opts{name};
}

sub unload_module {
    my ($event, $mod) = @_;
    # TODO: log
    $::pool->delete_event(user_match => $_) foreach $mod->list_store_items('matchers');
    return 1;
}

$mod