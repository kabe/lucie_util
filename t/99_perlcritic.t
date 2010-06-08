use strict;
use Test::More;

eval qq|use Test::Perl::Critic; Test::Perl::Critic->import(-profile => "t/perlcriticrc")|;
plan skip_all => "Test::Perl::Critic is not installed" if $@;

all_critic_ok("lib");
