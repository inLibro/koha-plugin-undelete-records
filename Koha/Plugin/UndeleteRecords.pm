package Koha::Plugin::UndeleteRecords;
# David Bourgault, 2017 - Inlibro
#
# This plugin allows you to undelete records and their items that you have deleted by mistake.
#
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
use Modern::Perl;
use strict;
use CGI;
use utf8;
use base qw(Koha::Plugins::Base);
use C4::Auth;
use C4::Context;
use Koha::DateUtils qw( dt_from_string );
use Data::Dumper;
use Koha::SearchEngine::Elasticsearch::Indexer;
use Koha::SearchEngine::Zebra::Indexer;
use Koha::SearchEngine;
use Koha::Biblios;
use Koha::Biblio;


our $VERSION = 1.1;
our $metadata = {
	name            => 'UndeleteRecords',
	author          => 'David Bourgault, Olivier Vézina, William Lavoie, Hammat Wele, Noah Tremblay',
	description     => 'Undelete records',
	date_authored   => '2017-11-15',
	date_updated    => '2026-01-27',
	minimum_version => '22.05',
	maximum_version => undef,
	version         => $VERSION,
};
our $dbh = C4::Context->dbh();
sub new {
	my ( $class, $args ) = @_;
	$args->{metadata} = $metadata;
	$args->{metadata}->{class} = $class;
	my $self = $class->SUPER::new($args);

	return $self;
}

sub tool {
    my ( $self, $args ) = @_;
	my $cgi = $self->{cgi};

	if ( $cgi->param('action') eq 'calculate') {
        my $target           = $cgi->param('target');
        my $records_or_items = $cgi->param('records_or_items');
        my $FromDate         = $cgi->param('FromDate');
        my $ToDate           = $cgi->param('ToDate');
		$self->calculate(
            $target,
            $records_or_items,
            $FromDate,
            $ToDate
        );
	}
	elsif ( $cgi->param('action') eq 'merge' and $cgi->param('confirm') eq 'confirm' ) {
        my $target               = $cgi->param('target');
        my $Type                 = $cgi->param('Type');
        my @selected_itemnumbers = $cgi->multi_param('selected_itemnumbers[]');
        $self->fusion(
            $target,
            $Type,
            @selected_itemnumbers,
		);
	}
	else {
		$self->home();
	}
}

sub tmpl {
	my $self = shift;
	my $cgi = $self->{cgi};
	my $preferedLanguage = $cgi->cookie('KohaOpacLanguage');

	my $template = undef;
	eval {$template = $self->get_template( { file => "home_" . $preferedLanguage . ".tt" } )};
	if( !$template ){
		$preferedLanguage = substr $preferedLanguage, 0, 2;
		eval {$template = $self->get_template( { file => "home_$preferedLanguage.tt" } )};
	}
	$template = $self->get_template( { file => 'home.tt' } ) unless $template;

	return $template
}

sub home {
	my $self = shift;
	my $cgi = $self->{cgi};
	my $template = $self->tmpl;
	print $cgi->header(-type => 'text/html',-charset => 'utf-8');
	print $template->output();
}

sub calculate {
    my $self = shift;
	my $target = shift;
    my $Type = shift or undef;
    my $FromDate = dt_from_string(shift);
    my $ToDate = dt_from_string(shift);
	my $cgi = $self->{cgi};
	my $template = $self->tmpl;
    my $all_deleted_sql = "";

    if($Type eq "Records"){
        $all_deleted_sql = "SELECT deletedbiblio.biblionumber, COALESCE(deletedbiblio.author, biblio.author),
        COALESCE(deletedbiblio.title,biblio.title),  deletedbiblioitems.isbn,
        deletedbiblioitems.issn, deletedbiblio.timestamp, deletedbiblio.datecreated
        FROM deletedbiblio
        LEFT JOIN biblio ON deletedbiblio.biblionumber = biblio.biblionumber
        LEFT JOIN deletedbiblioitems ON deletedbiblio.biblionumber = deletedbiblioitems.biblionumber
        WHERE deletedbiblio.timestamp >= '$FromDate'
            AND deletedbiblio.timestamp <= IF('$ToDate' LIKE '' AND '$FromDate' NOT LIKE '', NOW(), DATE_ADD('$ToDate', INTERVAL 1 DAY));";
    }elsif($Type eq "Items"){
        $all_deleted_sql = "SELECT deleteditems.itemnumber, deleteditems.barcode, COALESCE(deletedbiblio.title,biblio.title),
            COALESCE(deletedbiblio.author, biblio.author), COALESCE(deletedbiblioitems.isbn, biblioitems.isbn),
            COALESCE(deletedbiblioitems.issn, biblioitems.issn), deleteditems.biblionumber, deleteditems.timestamp, IF(deleteditems.barcode
            IN (
                SELECT items.barcode
                FROM items
                ), '*', '')
        FROM deleteditems
        LEFT JOIN deletedbiblioitems ON deleteditems.biblionumber = deletedbiblioitems.biblionumber
        LEFT JOIN deletedbiblio ON deleteditems.biblionumber = deletedbiblio.biblionumber
        LEFT JOIN biblio ON deleteditems.biblionumber = biblio.biblionumber
        LEFT JOIN biblioitems ON deleteditems.biblionumber = biblioitems.biblionumber
        WHERE deleteditems.timestamp >= '$FromDate'
            AND deleteditems.timestamp <= IF('$ToDate' LIKE '' AND '$FromDate' NOT LIKE '', NOW(), DATE_ADD('$ToDate', INTERVAL 1 DAY));";
    }
    # FIXME: prepared statement inutile/mal fait
    my $sth = $dbh->prepare($all_deleted_sql);
    $sth->execute();
    my @all_itemnumber = ( );
    my @all_barcode = ( );
    my @all_title = ( );
    my @all_author = ( );
    my @all_isbn = ( );
    my @all_issn = ( );
    my @all_biblio = ( );
    my @all_timestamp = ( );
    my @all_issimilarbarcode = ( );
    my @all_creationTime = ( );
    my $numberitems;
    if($Type eq "Records"){
      while(my @row = $sth->fetchrow_array()){
            push(@all_biblio, $row[0]);
            push(@all_author, $row[1]);
            push(@all_title, $row[2]);
            push(@all_isbn, $row[3]);
            push(@all_issn, $row[4]);
            push(@all_timestamp, $row[5]);
            push(@all_creationTime, $row[6]);
        }

        $numberitems = scalar @all_biblio;
    }elsif($Type eq "Items"){
        while(my @row = $sth->fetchrow_array()){
            push(@all_itemnumber, $row[0]);
            push(@all_barcode, $row[1]);
            push(@all_title, $row[2]);
            push(@all_author, $row[3]);
            push(@all_isbn, $row[4]);
            push(@all_issn, $row[5]);
            push(@all_biblio, $row[6]);
            push(@all_timestamp, $row[7]);
            push(@all_issimilarbarcode, $row[8]);
        }

        $numberitems = scalar @all_itemnumber;
    }

        $template->param(
            target => $target,
            type=>$Type,
            all_biblionumbers => \@all_biblio,
            all_itemnumbers => \@all_itemnumber,
            all_barcodes => \@all_barcode,
            all_authors => \@all_author,
            all_titles => \@all_title,
            all_timestamps => \@all_timestamp,
            all_creationTime => \@all_creationTime,
            all_issimilarbarcode => \@all_issimilarbarcode,
            all_isbn => \@all_isbn,
            all_issn => \@all_issn,
            from_date => $FromDate,
            to_date => $ToDate
        );


	print $cgi->header(-type => 'text/html',-charset => 'utf-8');
	print $template->output();

    return $numberitems;
}

sub fusion {
	my $self = shift;
	my $target = shift;
    my $Type = shift;
    my @selected_itemnumbers = @_ or undef;
	my $cgi = $self->{cgi};
	my $template = $self->tmpl;
    my $itemnumbers_sql = join ',', @selected_itemnumbers;
    $itemnumbers_sql = "''" unless $itemnumbers_sql;
    my @selected_biblionumbers = ( );
    my @selected_count = ( );
    my $undeleted_biblionumbers_sql = undef;
    if($Type eq "Records"){
        $undeleted_biblionumbers_sql = "SELECT biblionumber, count(*) FROM deletedbiblio WHERE biblionumber IN(";
    }
    else{
        $undeleted_biblionumbers_sql = "SELECT biblionumber, count(*) FROM deleteditems WHERE itemnumber IN(";
    }
    $undeleted_biblionumbers_sql .= $itemnumbers_sql;
    $undeleted_biblionumbers_sql .= ") GROUP BY biblionumber;";

    # FIXME: prepared statement inutile/mal fait
    my $sth = $dbh->prepare($undeleted_biblionumbers_sql);
    $sth->execute();
    while(my @retreived_items = $sth->fetchrow_array()){
        push(@selected_biblionumbers, $retreived_items[0]);
        push(@selected_count, $retreived_items[1]);
    }
    $template->param(
        type                   => $Type,
        selected_biblionumbers => \@selected_biblionumbers,
        selected_count         => \@selected_count
    );

    if($Type eq "Items"){
        #INSERT
        $dbh->do("INSERT INTO biblio
            SELECT *
            FROM deletedbiblio
            WHERE deletedbiblio.biblionumber IN (SELECT biblionumber FROM deleteditems
            WHERE itemnumber IN ($itemnumbers_sql))
                AND deletedbiblio.biblionumber
                    NOT IN (
                            SELECT biblionumber
                            FROM biblio)
        ;");
        $dbh->do("INSERT INTO biblioitems
            SELECT *
            FROM deletedbiblioitems
            WHERE deletedbiblioitems.biblionumber
                IN (
                    SELECT biblionumber
                    FROM deleteditems
                    WHERE itemnumber IN ($itemnumbers_sql)
                    )
                AND deletedbiblioitems.biblioitemnumber
                NOT IN (
                        SELECT biblioitemnumber
                        FROM biblioitems
                        )
        ;");
        $dbh->do("INSERT INTO biblio_metadata(biblionumber,format,`schema`,metadata)
            SELECT biblionumber,format,`schema`,metadata
            FROM deletedbiblio_metadata
            WHERE deletedbiblio_metadata.biblionumber
                IN (
                    SELECT biblionumber
                    FROM deleteditems
                    WHERE itemnumber IN ($itemnumbers_sql)
                    )
                AND deletedbiblio_metadata.biblionumber
                NOT IN (
                        SELECT biblionumber
                        FROM biblio_metadata
                        )
        ;");
        $dbh->do("UPDATE deleteditems
            SET barcode = IF(barcode
                IN (
                    SELECT barcode
                    FROM items
                    ),
                CONCAT(barcode, '_1'), barcode)
            WHERE deleteditems.itemnumber IN ($itemnumbers_sql)
        ;");
        $dbh->do("INSERT INTO items
            SELECT *
            FROM deleteditems
            WHERE deleteditems.itemnumber IN ($itemnumbers_sql)
        ;");
        #DELETE
        $dbh->do("DELETE FROM deleteditems
            WHERE deleteditems.itemnumber IN ($itemnumbers_sql)
        ;");
        $dbh->do("DELETE FROM deletedbiblioitems
            WHERE deletedbiblioitems.biblionumber
                IN (
                    SELECT biblionumber
                    FROM items
                    WHERE itemnumber IN ($itemnumbers_sql))
                        AND deletedbiblioitems.biblionumber
                        IN (
                            SELECT biblionumber
                            FROM biblioitems
                            )
        ;");
        $dbh->do("DELETE FROM deletedbiblio_metadata
            WHERE deletedbiblio_metadata.biblionumber
                IN (
                    SELECT biblionumber
                    FROM items
                    WHERE itemnumber IN ($itemnumbers_sql))
                        AND deletedbiblio_metadata.biblionumber
                        IN (
                            SELECT biblionumber
                            FROM biblio_metadata
                            )
        ;");
        $dbh->do("DELETE FROM deletedbiblio
            WHERE deletedbiblio.biblionumber
                IN (
                    SELECT biblionumber
                    FROM items
                    WHERE itemnumber IN ($itemnumbers_sql))
                        AND deletedbiblio.biblionumber
                        IN (
                            SELECT biblionumber
                            FROM biblio
                            )
        ;");
    }
    elsif($Type eq "Records"){

         $dbh->do("INSERT INTO biblio
            SELECT *
            FROM deletedbiblio
            WHERE deletedbiblio.biblionumber IN ($itemnumbers_sql) AND
                    deletedbiblio.biblionumber NOT IN (
                            SELECT biblionumber
                            FROM biblio)
        ;");

        $dbh->do("INSERT INTO biblioitems
            SELECT *
            FROM deletedbiblioitems
            WHERE deletedbiblioitems.biblionumber
                IN ($itemnumbers_sql)
                AND deletedbiblioitems.biblioitemnumber
                NOT IN (
                        SELECT biblioitemnumber
                        FROM biblioitems
                        )
        ;");


        $dbh->do("INSERT INTO biblio_metadata(biblionumber,format,`schema`,metadata)
            SELECT biblionumber,format,`schema`,metadata
            FROM deletedbiblio_metadata
            WHERE deletedbiblio_metadata.biblionumber
                IN (
                    SELECT biblionumber
                    FROM deletedbiblio
                    WHERE biblionumber IN ($itemnumbers_sql)
                    )
                AND deletedbiblio_metadata.biblionumber
                NOT IN (
                        SELECT biblionumber
                        FROM biblio_metadata
                        )
        ;");

        $dbh->do("DELETE FROM deletedbiblioitems
            WHERE deletedbiblioitems.biblionumber
                IN ($itemnumbers_sql)
            AND deletedbiblioitems.biblionumber
                IN (
                    SELECT biblionumber
                    FROM biblioitems
                    )
        ;");


        $dbh->do("DELETE FROM deletedbiblio_metadata
            WHERE deletedbiblio_metadata.biblionumber
                IN (
                    SELECT biblionumber
                    FROM biblio
                    WHERE biblionumber IN ($itemnumbers_sql)
                    )
                AND deletedbiblio_metadata.biblionumber
                    IN (
                        SELECT biblionumber
                        FROM biblio_metadata
                        )
        ;");

        $dbh->do("DELETE FROM deletedbiblio
            WHERE deletedbiblio.biblionumber
                    IN (
                        SELECT biblionumber
                        FROM biblio
                        )
        ;");

    }

	print $cgi->header(-type => 'text/html',-charset => 'utf-8');
	print $template->output();

    my $search_engine = C4::Context->preference("SearchEngine");

    # Retrieve selected biblionumbers
    my @biblio_ids = @selected_biblionumbers;

    # Fetch all records by looping through the biblionumbers
    my @records;
    foreach my $biblionumber (@biblio_ids) {
        my $biblio = Koha::Biblios->find($biblionumber);
        unless ($biblio) {
            warn "Skip undeleted biblionumber $biblionumber: no biblio found";
            next;
        }

        my $marc_record;
        eval { $marc_record = $biblio->record(); };
        if ($@ or !$marc_record) {
            warn "Skip undeleted biblionumber $biblionumber: no valid MARC metadata";
            next;
        }

        push @records, $marc_record;
    }

    if ($search_engine eq 'Zebra') {
        my $zebra_indexer = Koha::SearchEngine::Zebra::Indexer->new({ index => $Koha::SearchEngine::BIBLIOS_INDEX});
        # Reindex the retrieved records
        $zebra_indexer->index_records(\@biblio_ids, "update", "biblioserver", undef);
    }
    elsif ($search_engine eq 'Elasticsearch') {
        my $elastic_indexer = Koha::SearchEngine::Elasticsearch::Indexer->new({ index => $Koha::SearchEngine::BIBLIOS_INDEX});
        # Reindex the retrieved records
        $elastic_indexer->update_index(\@biblio_ids);
    }
    else {
        die "Unknown search engine: $search_engine. Unable to reindex.";
    }
}


#Supprimer le plugin avec toutes ses données
sub uninstall() {
    my ( $self, $args ) = @_;
    return 1; # succès
}
