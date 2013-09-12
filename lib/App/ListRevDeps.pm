package App::ListRevDeps;

use 5.010;
use strict;
use warnings;
use Log::Any qw($log);

our %SPEC;
require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(list_prereqs);

# VERSION

$SPEC{list_rev_deps} = {
    v => 1.1,
    summary => 'List prerequisites of a Perl module',
    description => <<'_',

Currently skips prerequisites which are modules already in core (for installed
perl version).

_
    args => {
        module => {
            schema  => ['array*'], # XXX of str*
            summary => 'Perl module(s) to check',
            req     => 1,
            pos     => 0,
            greedy  => 1,
        },
        level => {
            schema  => [int => {default=>1}],
            summary => 'Specify how many levels up to check (-1 means unlimited)',
            #cmdline_aliases => { l => {} },
        },
        recursive => {
            schema  => ['bool'],
            summary => 'Equivalent to setting level=-1',
            cmdline_aliases => { r => {} },
        },
        #cache => {
        #    schema  => [bool => {default=>1}],
        #    summary => 'Whether to cache API results for some time, '.
        #        'for performance',
        #},
        raw => {
            schema  => [bool => {default=>0}],
            summary => 'Return raw result',
        },
        # TODO: arg to set cache root dir
        # TODO: arg to set default cache expire period
    },
};
sub list_rev_deps {
    require CHI;
    require LWP::UserAgent;
    require MetaCPAN::API;
    require Mojo::DOM;
    require Module::CoreList;

    state $ua = do { my $ua = LWP::UserAgent->new; $ua->env_proxy; $ua };

    my %args = @_;
    # XXX schema
    my $mod = $args{module} or return [400, "Please specify module"];
    my $maxlevel = $args{level} // 1;
    $maxlevel = -1 if $args{recursive};
    #my $do_cache = $args{cache} // 1;
    my $raw = $args{raw};

    # '$cache' is ambiguous between args{cache} and CHI object
    my $chi = CHI->new(driver => "File");

    my $mcpan = MetaCPAN::API->new;

    my $cp = "list_rev_deps"; # cache prefix
    my $ce = "24h"; # cache expire period

    my @errs;
    my %mdist; # mentioned dist, for checking circularity
    my %mmod;  # mentioned mod

    my $do_list;
    $do_list = sub {
        my ($dist, $level) = @_;
        $level //= 0;
        $log->debugf("Listing reverse dependencies for dist %s (level=%d) ...", $mod, $level);

        my @res;

        if ($mdist{$dist}++) {
            push @errs, "Circular dependency (dist=$dist)";
            return ();
        }

        # list dists which depends on $dist
        my $depdists = $chi->compute(
            "$cp-dist-$dist", $ce, sub {
                $log->infof("Querying MetaCPAN for dist %s ...", $dist);
                my $url = "https://metacpan.org/requires/distribution/$dist";
                my $res = $ua->get($url);
                die "Can't get $url: " . $res->status_line unless $res->is_success;
                my $dom = Mojo::DOM->new($res->content);
                my @urls = $dom->find(".release-table td.name a[href]")->pluck(attr=>"href")->each;
                my @dists;
                for (@urls) {
                    s!^/release/!!;
                    push @dists, $_;
                }
                \@dists;
            });

        for my $d (@$depdists) {
            my $res = {
                dist => $d,
            };
            if ($level < $maxlevel-1 || $maxlevel == -1) {
                $res->{rev_deps} = [$do_list->($d, $level+1)];
            }
            if ($raw) {
                push @res, $res;
            } else {
                push @res, join(
                    "",
                    "    " x $level,
                    $res->{dist},
                    "\n",
                    join("", @{ $res->{rev_deps} // [] }),
                );
            }
        }

        @res;
    };

    my @res;
    for (ref($mod) eq 'ARRAY' ? @$mod : $mod) {
        my $modinfo = $chi->compute(
            "$cp-mod-$_", $ce, sub {
                $log->infof("Querying MetaCPAN for module %s ...", $_);
                $mcpan->module($_);
            });
        my $dist = $modinfo->{distribution};
        push @res, $do_list->($dist);
    }
    my $res = $raw ? \@res : join("", @res);

    [200, @errs ? "Unsatisfiable dependencies" : "OK", $res,
     {"cmdline.exit_code" => @errs ? 200:0}];
}

1;
#ABSTRACT: List reverse dependencies of a Perl module

=head1 SYNOPSIS

 # Use via list-rev-deps CLI script


=head1 DESCRIPTION

Currently uses MetaCPAN API and also scrapes the MetaCPAN website and by default
caches results for 24 hours.


=head1 SEE ALSO

=cut
