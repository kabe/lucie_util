use Test::More tests => 4;
use LDB;

my $ldb = new LDB;
my $status_ok = new Status(1);
my $status_fail = new Status(0, "Error Message");

# Test

is $status_ok->isError, 0;
is $status_ok->message, undef;

is $status_fail->isError, 1;
is $status_fail->message, "Error Message";

