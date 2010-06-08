use Test::More tests => 4;
use LDB;
use Data::Dumper;

my $ldb = new LDB;
my $status_ok = new Status(1);
my $status_notconfigured = new Status(0, "Not configured yet");
my $status_notgetattr = new Status(0, "No getattr");

my $conf = {
            nodelist => "hongo100",
            "nocheck-secret-file" => 1,
            "lucie-wc" => "/home/kabe/git/lucie",
            "ldb-wc" => "/home/kabe/git/L4",
           };
my $stat;

is $ldb->{verbose}, 0;
# Pre-configuration
is_deeply $ldb->getattr(), $status_notconfigured;
is_deeply $ldb->getinfo(), $status_notgetattr;

# Configure
$stat = $ldb->configure($conf);
is_deeply $stat, $status_ok;

