package DBI::Forward::Execute;

use strict;
use warnings;

use DBI;
use DBI::Forward::Request;
use DBI::Forward::Response;

use base qw(Exporter);

our @EXPORT_OK = qw(
    execute_request
    execute_dbh_request
    execute_sth_request
);

our @sth_std_attr = qw(
    NUM_OF_PARAMS
    NUM_OF_FIELDS
    NAME
    TYPE
    NULLABLE
    PRECISION
    SCALE
    CursorName
);

sub _connect {
    my $request = shift;
    my $connect_args = $request->connect_args;
    my ($dsn, $u, $p, $attr) = @$connect_args;
    # XXX need way to limit/purge connect cache over time
    my $dbh = DBI->connect_cached($dsn, $u, $p, {
        %$attr,
        # override some attributes
        PrintWarn  => 0,
        PrintError => 0,
        RaiseError => 1,
    });
    # $dbh->trace(2);
    return $dbh;
}

sub execute_request {
    my $request = shift;
    my $response = eval {
        ($request->is_sth_request)
            ? execute_sth_request($request)
            : execute_dbh_request($request);
    };
    if ($@) {
        warn $@; # XXX
        $response = DBI::Forward::Response->new({
            err => 1, errstr => $@, state  => '',
        });
    }
    return $response;
}

sub execute_dbh_request {
    my $request = shift;
    my $dbh;
    my $rv = eval {
        $dbh = _connect($request);
        my $meth = $request->dbh_method_name;
        my $args = $request->dbh_method_args;
        my @rv = ($request->dbh_wantarray)
            ?        $dbh->$meth(@$args)
            : scalar $dbh->$meth(@$args);
        \@rv;
    };
    my $response = DBI::Forward::Response->new({
        rv     => $rv,
        err    => $DBI::err,
        errstr => $DBI::errstr,
        state  => $DBI::state,
    });
    $response->last_insert_id = $dbh->last_insert_id( @{ $request->dbh_last_insert_id_args })
        if $dbh && $rv && $request->dbh_last_insert_id_args;
    return $response;
}

sub execute_sth_request {
    my $request = shift;
    my $dbh;
    my $rv;
    my $resultset_list = eval {
        $dbh = _connect($request);

        my $meth = $request->dbh_method_name;
        my $args = $request->dbh_method_args;
        my $sth = $dbh->$meth(@$args);

        for my $meth_call (@{ $request->sth_method_calls }) {
            my $method = shift @$meth_call;
            $sth->$method(@$meth_call);
        }

        $rv = $sth->execute();

        my $attr_list = $request->sth_result_attr;
        $attr_list = [ keys %$attr_list ] if ref $attr_list eq 'HASH';
        my $rs_list = [];
        do {
            my $rs = fetch_result_set($sth, $attr_list);
            push @$rs_list, $rs;
        } while $sth->more_results;

        $rs_list;
    };
    my $response = DBI::Forward::Response->new({
        rv     => $rv,
        err    => $DBI::err,
        errstr => $DBI::errstr,
        state  => $DBI::state,
        sth_resultsets => $resultset_list,
    });

    return $response;
}

sub fetch_result_set {
    my ($sth, $extra_attr) = @_;
    my %meta;
    for my $attr (@sth_std_attr, @$extra_attr) {
        $meta{ $attr } = $sth->{$attr};
    }
    $meta{rowset} = $sth->fetchall_arrayref();
    return \%meta;
}

1;
