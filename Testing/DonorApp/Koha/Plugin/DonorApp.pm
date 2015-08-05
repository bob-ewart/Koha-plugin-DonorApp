package Koha::Plugin::DonorApp;

# Copyright 2015 Robert Ewart
#
# This file is part of a Koha plugin.
#
#
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.


## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Branch;
use C4::Members;
use C4::Members::Attributes;
use C4::Auth;
use IO::Handle;
use File::Basename;
use Data::Dumper::Concise;
use Spreadsheet::Read;
use DateTime::Format::Excel;
use Excel::Writer::XLSX;
use Lingua::EN::MatchNames;
use Lingua::EN::NameParse;
use String::Similarity;
use Date::Manip;


## Here we set our plugin version
our $VERSION = 4.00;
our ( @businessFlag,
      $new_tables,
      %Attributes,
      %Branches,
      %Categories,
      $multibranch,
   #   $logo,
);

## Here is our metadata, some keys are required, some are optional
our $metadata = {
        name   => 'Donor Application',
        author => 'Bob Ewart',
        description =>'This plugin will process donor data',
        date_authored   => '2015-01-08',
        date_updated    => '2015-08-03',
        minimum_version => '3.18',
        maximum_version => undef,
        version         => $VERSION,
};


## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);
    check_tables();
    get_branchCodes();
    get_categoryCodes();
    get_attributes();
  #  $logo = C4::Context->config('pluginsdir')."/Koha/Plugin/DonorApp/includes/boda-logo.gif";
    return $self;
}



## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
  my ( $self, $args ) = @_;
  require  DonorApplib::Configure;
  DonorApplib::Configure->import();
  do_mysql_source($self,ipath()."/boda-table-drop.sql");
  return 1;
}

## The existance of a 'tool' subroutine means the plugin is capable
## of running a tool. The difference between a tool and a report is
## primarily semantic, but in general any plugin that modifies the
## Koha database should be considered a tool
sub tool {
  my ( $self, $args ) = @_;
  my $message='';
  if (!configured()) {
    configure($self);
    return;
  }
  my $cgi = $self->{cgi};
  my $dbh = C4::Context->dbh;
  my $action = ($cgi->param('action')) || '';
  my $subaction = ($cgi->param('subaction')) || '';
  my $borrowernumber = C4::Context->userenv->{number};
  my $borrower = GetMember( borrowernumber => $borrowernumber );
  my $cardnumber = $borrower->{cardnumber};
  my $sth = $dbh->prepare("SELECT snuser, permissions FROM bodausers WHERE cardnumber=?");
  $sth->execute($cardnumber);
  my ($snuser,$snperm) = $sth->fetchrow_array;
  my $trace = $self->retrieve_data('mytrace') || 0;
  my $taction = scalar $cgi->param('taction') || '';
  if ($taction eq 'trace') {
    $self->tool_trace($message,$snperm,$action,$subaction,$trace);
  } else {
    if ($trace & 1) {
      $sth = $dbh->prepare("INSERT INTO bodatrace SET action=?,subaction=?,parm=?");
      my @pnames = $cgi->param;
      my @pvalues;
      foreach my $pname (@pnames) {
        if (($pname eq 'method') || ($pname eq 'class')) { next; }
        my ($ptype,$pvalue)= myref(scalar $cgi->param($pname));
        push @pvalues,"$pname=$pvalue";
      }
      $sth->execute("->".$action,$subaction,join(', ',@pvalues));
    }
    if (!$snuser) {
      $action = 'Home';
      $message = "User not authorized";
    } elsif (!$action) {
      $sth = $dbh->prepare("INSERT INTO bodalog SET loggedon=NOW(), snuser=?");
      $sth->execute($snuser);
      $action = 'Home';
    }
    if ($action eq 'Home') {
      $self->tool_home($message,$snperm,$action,$subaction,$trace);
    } elsif ($action eq 'Show') {
      $self->tool_show($message,$snperm,$action,$subaction,$cardnumber,$trace);
    } elsif ($action eq 'Year') {
      $self->tool_year($message,$snperm,$action,$subaction,$trace);
    } elsif ($action eq 'Reports') {
      $self->tool_reports($message,$snperm,$action,$subaction,$snuser,$trace);
    } elsif ($action eq 'System update') {
      $self->tool_system($message,$snperm,$action,$subaction,$trace);
    } elsif ($action eq 'Upload') {
      $self->tool_upload($message,$snperm,$action,$subaction,$trace);
    } elsif ($action eq 'trace') {
      $self->tool_trace($message,$snperm,$action,$subaction,$trace);
    } elsif ($action eq 'Swap') {
      $self->tool_swap($message,$snperm,$action,$subaction,$cardnumber,$trace);
    } else {
      $self->tool_home("Action $action - $subaction not implemented",$snperm,$action,$subaction,$trace);
    }
  }
}

=for
Trace flags
'001' = 'Actions',
'002' = 'Modify report',
'004' = 'NewDonor other',
'008  = 'reports SQL',
'016' = 'reports other',
'032' = 'System',
'064' = 'Upload'
'128' = 'trace routine'
'512' = 'swap'
=cut



sub tool_home {
    my ( $self, $message,$snperm,$action,$subaction,$trace)  = @_;
    my $cgi = $self->{'cgi'};
    my %perm;
    foreach (split(',',$snperm)){
      $perm{$_} = 1;
    }
    my $userenv = C4::Context->userenv;
    if (C4::Auth::haspermission($userenv->{'id'},{'borrowers'=>1})) {
      $perm{borrowers} = 1;
    }
    my $template = $self->get_template({ file => 'home.tt' });
    #$template->param('logo',$logo);
    $template->param('message',$message);
    $template->param('permissions',\%perm);
    $template->param('ipath',ipath());
    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare("SELECT repid,report_name FROM bodareports ORDER BY repid");
    $sth->execute;
    my $reports = $sth->fetchall_arrayref;
    $template->param('reports',$reports);
    $template->param('action','Show');
    print $cgi->header();
    print $template->output();
}
 
sub tool_upload {
  my ( $self, $message,$snperm,$action,$subaction,$trace) = @_;
  my ($template,$badFunds,$acctTotals,$updatedPatrons,$drange,$xlsxin,$sth);
  my $startTime = time();
  my $cgi = $self->{'cgi'};
  my $dbh = C4::Context->dbh;
  my $sttrace = $dbh->prepare("INSERT INTO bodatrace SET action=?,subaction=?,parm=?");
  my $fchk = $dbh->prepare("SELECT QBname,fundcard FROM bodafunds WHERE fundcard like 'bf%' order by QBname");
  my ($fund,$fundcard,$fundname,$newCard,%bfund);
  my $stdf = $dbh->prepare("UPDATE bodadonations SET fund=? WHERE fund=?");
  my $stdc = $dbh->prepare("UPDATE bodadonations SET cardnumber=? WHERE cardnumber=?");
  my $stf = $dbh->prepare("UPDATE bodafunds SET fundcard=? WHERE fundcard=?");

  $template = $self->get_template({file => 'home.tt'});
  if ($subaction eq 'Update funds') {
    my @fundcards = $cgi->param;
    foreach $fund (@fundcards) {
      if ($fund =~ m/bf\d+/) {              #bad fund temp value
        $fundcard = $cgi->param($fund);
        if ($fundcard) {
          $stdf->execute($fundcard,$fund);
          $stdc->execute($fundcard,$fund);
          $stf->execute($fundcard,$fund);
        }
      }
    }
    $fchk->execute;
    $message = "Funds Updated ";
    while (($fundname,$fundcard) = $fchk->fetchrow_array) {
      my $newCard = fixup_cardnumber(' ');
      my %borrower = (surname=>$fundname,address=>' ',cardnumber=>$newCard,
                      city=>' ',zipcode=>'00000',categorycode=>'FUND',
                      branchcode=>'SLA',privacy=>1);
      if (!AddMember(%borrower)) {
        $message .= "$fundname error, ";
      } else {
        $stdf->execute($newCard,$fundcard);
        $stdc->execute($newCard,$fundcard);
        $stf->execute($newCard,$fundcard);
        $message .= "$fundname added as $newCard, ";
      }
    }
    $self->tool_home($message,$snperm,'Home',' ',$trace);
    return;
  }
  my $filename = $cgi->param('excel');
  $message = '';
  if (!$filename) {
    $message = "You need to specify a filename";
  } else {
    ($xlsxin,$message) = move_excel($filename,$cgi);
  }
  $sttrace->execute('Upload',"file","$filename traces=$trace");
  
  if (!$message) {
    ($message,$drange,$updatedPatrons,$badFunds,$acctTotals) = upload_qb($xlsxin,$trace);
    $template = $self->get_template({file => 'upload.tt'});
    if ($badFunds) {
      $fchk->execute;
      $template->param('badFunds',$fchk->fetchall_arrayref);
      $template->param('funds',get_funds($dbh));
    }
    $template->param('drange',$drange);
    $template->param('patrons',$updatedPatrons);
    $template->param('acctTotals',$acctTotals);
    #$message = "acctTotals: ".Dumper($acctTotals);
  }
  ($trace & 64) && $sttrace->execute("Upload","Time",time()-$startTime);
  $template->param('message',$message);
  $template->param('ipath',ipath());
  print $cgi->header();
  print $template->output();
}

sub tool_swap {
  my ( $self, $message,$snperm,$action,$subaction,$ucardnumber,$trace) = @_;
  my $cgi = $self->{'cgi'};
  my $dbh = C4::Context->dbh;
  my $sttrace = $dbh->prepare("INSERT INTO bodatrace SET action=?,subaction=?,parm=?");
  my $card = $cgi->param('card');
  my $borrower = &GetMemberDetails(0,$card);
  if (!$borrower) {
    $message .= " Card $card not found";
  } else {
    my (%newdata,$field,$city,$state);
    $newdata{borrowernumber} = $borrower->{borrowernumber};
    my @fields = qw(streetnumber address address2 city state zipcode country email phone);
    foreach $field (@fields) {
      $newdata{$field} = ($borrower->{'B_'.$field} || '');
      $newdata{'B_'.$field} = ($borrower->{$field} || '');
      ($trace & 512) && $sttrace->execute('swap',$field,"'$newdata{$field}' <=> '$newdata{'B_'.$field}'");
    }
    if (!$newdata{state}) {
      if (exists $newdata{city}) {
        $city = $newdata{city};
        if ($city =~ m/\W(\w\w)\s*$/) {
          $newdata{state} = $1;
          $city = substr($city,0,$-[0]);
          $city =~ s/,\s*$//;
          $newdata{city} = $city if $city;
          ($trace & 512) && $sttrace->execute('-City'.$newdata{city},$newdata{state});
        }
      }
    }
      
    if (scalar(keys %newdata) <=1 ) {
      $message = " no data to swap";
      $trace && $sttrace->execute($action,$card,"No data to swap");
    } else {
      &ModMember(%newdata);
      $message = "Addresses swapped";
    }
  }
  $self->tool_show($self,$message,$snperm,$action,'',$ucardnumber,$trace);  
}

sub tool_show {
    my ( $self, $message,$snperm,$action,$subaction,$ucardnumber,$trace) = @_;

    my $cgi = $self->{'cgi'};
    my ($template, %donations,$amt,$year,$rev,$sth,%cards,$dbh,$card,$name);

    $dbh = C4::Context->dbh;
    $card = $cgi->param('card');
    $name = $cgi->param('patron');
    my $sttrace = $dbh->prepare("INSERT INTO bodatrace SET action=?,subaction=?,parm=?");
#---------------------------------------No name or card
    if (!$name && !$card) {
      $template = $self->get_template({file => 'home.tt'});
      $message="Enter a name or card number";
    }
#---------------------------------------Name Given not card
    if ($name && !$card) {
      %cards = find_patron($name,$trace);          # Search on name
      if (scalar(keys %cards) > 1) {               # Many names -> select one
        $template = $self->get_template({file => 'patron_many.tt'});
        $template->param('cards',\%cards);
        $subaction = 'Show';
        $card = '';
      } else {
        ($card) = keys %cards;                          # Found one, use the card
        $template = $self->get_template({file => 'home.tt'});
        $message = "$name not found";
      }
    }
    #
    # Show the Patron by Card
    #
    if ($card){                                        # Show the patron
      $template = $self->get_template({ file => 'patron_show.tt' });
      $message = '';
      my $userenv = C4::Context->userenv;
      if (C4::Auth::haspermission($userenv->{'id'},{'borrowers'=>1})) {
        $template->param('borrower',1);
      }
      my $borrower = &GetMemberDetails(0,$card);
      if (!$borrower) {
        $self->tool_home("Card $card does not exist",$snperm,$action,$subaction,$trace);
        return;
      }
      my ($img,$imgerr) = GetPatronImage($borrower->{borrowernumber});
      $borrower->{has_picture} = 1 if $img;
      $borrower = patron_attributes($borrower,$trace);
      $template->param( 'patron' => $borrower );
      ($trace & 16) && $sttrace->execute('picture',$borrower->{cardnumber},($borrower->{has_picture})?'has Picture':'No Picture');
      my %donations;

      if ($borrower->{categorycode} eq 'FUND') {
        $sth = $dbh->prepare("SELECT sum(donamt) total, year(dondate) dyear ".
                             "FROM bodadonations WHERE cardnumber=? or fund=?".
                             "group by dyear order by dyear desc");
        $sth->execute($card,$card);
      } else {
        $sth = $dbh->prepare("SELECT SUM(donamt),YEAR(dondate) FROM bodadonations WHERE cardnumber=? ".
                              " GROUP BY YEAR(dondate) ORDER BY YEAR(dondate) DESC");
        $sth->execute($card);
      }
      my $total = 0;
      while (($amt,$year) = $sth->fetchrow_array) {
        $total += $amt;
        $donations{$year} = commify($amt);
      }
      $total = commify($total);
      $template->param('donations',\%donations);
      $template->param('total',$total);
      $template->param('card',$card);


      if ($subaction eq 'Add Comment') {
        my $comments = $cgi->param('comments');
        if ($comments) {
          $comments = fix_html($comments);
          my $stcom = $dbh->prepare("INSERT INTO bodacontact SET pcardnumber=?, ucardnumber=?,".
                                    "created=NOW(),comments=?");
          $stcom->execute($card,$ucardnumber,$comments);
        }
      }
      my $stcomnt = $dbh->prepare("SELECT DATE(lastupdate),comments,concat_ws(' ',firstname,surname) ".
                                  " FROM bodacontact LEFT JOIN borrowers ON (cardnumber = ucardnumber) ".
                                  " WHERE pcardnumber=? ORDER BY lastupdate desc");
      my $prevComments='';
      $stcomnt->execute($card);
      while (my ($comdate,$comments,$comby) = $stcomnt->fetchrow_array) {
        $prevComments .= "----$comdate  $comby\n".unfix_html($comments)."\n";
      }
      $template->param('prevComments',$prevComments);
    }
#----------------------------------------------------All done, set the usual parameters
    $template->param('message',$message);
    $template->param( 'ipath',ipath() );
    $template->param( 'action' => $action );
    $template->param( 'subaction' => $subaction );
    print $cgi->header();
    print $template->output();
}

sub tool_year {
  my ( $self, $message,$snperm,$action,$subaction,$trace) = @_;
  my $cgi = $self->{'cgi'};

  my $template = $self->get_template({ file => 'patron_year.tt' });
  $template->param('message',$message);
  my $year = $cgi->param('year');
  my $card = $cgi->param('card');
  my $borrower = &GetMemberDetails(0,$card);
  $borrower = patron_attributes($borrower,$trace);
  $template->param( 'patron' => $borrower );
  $template->param( 'card' => $card );
  $template->param( 'year' => $year );
  my ($dbh,$sth,$hashref,@donations,$amt,$rev,$funder);

  $dbh = C4::Context->dbh;
  my $sttrace = $dbh->prepare("INSERT INTO bodatrace SET action=?,subaction=?,parm=?");
  if ($borrower->{categorycode} eq 'FUND') {
    $sth = $dbh->prepare("SELECT dondate,donamt,description,acctdesc,deductible,cardnumber,fund ".
                          "FROM bodadonations d left join bodaaccts a on (d.donacct = a.donacct) ".
                          " WHERE (cardnumber = ? or fund=?) AND year(dondate) = ? ORDER BY dondate");
    $sth->execute($card,$card,$year);
  } else {
    $sth = $dbh->prepare("SELECT dondate,donamt,description,acctdesc,deductible,cardnumber,fund ".
                          "FROM bodadonations d left join bodaaccts a on (d.donacct = a.donacct) ".
                          " WHERE cardnumber = ? AND year(dondate) = ? ORDER BY dondate");
    $sth->execute($card,$year);
  }
  my ($total,$ded);
  while ($hashref = $sth->fetchrow_hashref) {
    $amt = $hashref->{donamt} + 0;
    $total += $amt;
    if ($hashref->{deductible}) {
      $ded += $amt;
    }
    $amt = commify($amt);
    $hashref->{donamt} = $amt;
    my $fund = $hashref->{fund};
    if (defined $fund) {
      if ($fund ne $card) {
        $funder =  &GetMemberDetails(0,$fund);
        $fund = "<input type='submit' name='card' value='$fund' /> ".join (' ',$funder->{firstname}||'',$funder->{surname});
      } else {
        $fund = ' ';
      }
    } else {
      $fund = ' ';
    }
    $hashref->{fund} = $fund;
    push @donations,$hashref;
  }
  $template->param('yeardon',\@donations);
  $template->param('total',commify($total));
  $template->param('ded',commify($ded));
  $template->param( 'action' => 'Show' );
  $template->param('ipath',ipath());
  print $cgi->header();
  print $template->output();
}

sub tool_reports {
  my ( $self, $message,$snperm,$action,$subaction,$snuser,$trace) = @_;
  my $cgi = $self->{'cgi'};
  my $dbh = C4::Context->dbh;
  my $sttrace = $dbh->prepare("INSERT INTO bodatrace SET action=?,subaction=?,parm=?");
  my %perm;
  foreach (split(',',$snperm)){
    $perm{$_} = 1;
  }
  my ($template,$repid,$qrep,$repdef,$excelFile);
  $repid = $cgi->param('repid');

#-------------------------------------------------Delete a report and go back to home
  if ($subaction eq 'Delete') {
    my $report_name = $cgi->param('report_name');
    $qrep = $dbh->prepare("DELETE FROM bodareports WHERE repid=?");
    if ($qrep->execute($repid)) {
      $self->tool_home("Report ($repid) $report_name Deleted",$snperm,$action,$subaction);
    } else {
      $self->tool_home("Report ($repid) $report_name Not Deleted",$snperm,$action,$subaction);
    }

#-------------------------------------------------Save or Update a report

  } else {
    if (($subaction eq 'Save') or ($subaction eq 'Update')) {
      ($repid,$message) = save_report($cgi,$repid,$subaction,$snuser,$trace);
      if ($repid) {
        $subaction = 'Run';
      } else {
        $subaction = "Fix";
        $message .="<br />Report not saved";
      }
    }

#-----------------------------------------------Get the data for show
    if ($subaction eq 'Run') {
      $qrep = $dbh->prepare("SELECT report_name, savedsql, notes, selcodes FROM bodareports WHERE repid=?");
      $qrep->execute($repid);
      my ($report_name,$query,$description,$selectcodes) = $qrep->fetchrow_array;
      $excelFile = $report_name.'-'.$snuser.".xlsx";
      $excelFile =~ s/\s/_/g;
      $description = unfix_html($description);
      $query = unfix_html($query);
      $qrep = $dbh->prepare("UPDATE bodareports SET last_run = NOW() WHERE repid=?");
      $qrep->execute($repid);
      my ($headers,$records,$formats) = get_data($query,$selectcodes,$excelFile,$trace);
      if ($records) {
        $template = $self->get_template({ file => 'report_show.tt' });
        my (@comCols,$i,$j,$n);
        for ($i=0; $i < @$formats; $i++) {
          if ($formats->[$i] == 2) {
            push @comCols,$i;
          }
        }
        ($trace & 4) && $sttrace->execute('run','commify',join(', ',@comCols));
        ($trace & 4) && $sttrace->execute('run','excel',$excelFile);
        for ($i=0; $i < @$records; $i++) {
          foreach $j (@comCols) {
            $records->[$i]->[$j] = commify(($records->[$i]->[$j]) || 0);
          }
        }
        print $cgi->header;
        $template->param('permissions',\%perm);
        $template->param('headers',$headers);
        $template->param('formats',$formats);
        $template->param('records',$records);
        $template->param('repid',$repid);
        $template->param('report_name',$report_name);
        $template->param('description',$description);
        $template->param('message',$message);
        $template->param('ipath',ipath());
        $template->param('action',$action);
        $template->param('subaction',$subaction);
        $template->param('excelFile',$excelFile);
        print $template->output;
        return 1;
      } else {
        $subaction = 'Fix';
        $message = 'No records found';
      }

    } elsif ($subaction eq 'Download') {
      $excelFile = scalar $cgi->param('excelFile');
      my $excelDir = C4::Context->config('pluginsdir')."/Koha/Plugin/DonorApp/uploads/";
      ($trace & 4) && $sttrace->execute('download',$excelFile,(-s $excelDir.$excelFile) );
      print "Content-type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet\n";
      print "Content-Disposition: attachment; filename=$excelFile\n";
      print "Content-Description: Donor spreadsheet to download\n\n";

      open(FH, "< :raw", $excelDir.$excelFile);
      my ($bytesRead,$buffer);

      while ($bytesRead = read(FH, $buffer, 1024)) {
        print $buffer;
      }
      return;
    }
  #---------------------------------------------------Edit or New

    if (($subaction eq 'Edit') || ($subaction eq 'New') || ($subaction eq 'Fix')) {
      $template = $self->get_template({ file => 'report_edit.tt' });
      if ($subaction eq 'New') {
        $repid = 0;
        $repdef->{field} = join(',',(qw/ First_Name Surname Address1 Address2
                                        City State ZIP Phone Email Expiry Branch/));
        $repdef->{tottype} = 'total';
        $repdef->{orderby} = 'card';
      } elsif ($subaction eq 'Edit') {                         # Get the report definition
        $qrep = $dbh->prepare("SELECT * FROM bodareports WHERE repid=?");
        $qrep->execute($repid);
        $repdef = $qrep->fetchrow_hashref;
      } elsif ($subaction eq 'Fix') {
        $repdef = set_repdef($cgi,$trace);
      }
      $repdef->{field} = hashify($repdef->{field});
      $repdef->{acctlim} = hashify($repdef->{acctlim});
      $repdef->{catcodes} = hashify($repdef->{catcodes});
      $repdef->{selcodes} = hashify($repdef->{selcodes});
      $repdef->{branches} = hashify($repdef->{branches});
      $repdef->{multibranch} = $multibranch;
      
      $template->param('repdef',$repdef);
      $qrep = $dbh->prepare("SELECT donacct, acctdesc FROM bodaaccts ORDER BY qb desc, donacct");
      $qrep->execute;
      my $acctref = $qrep->fetchall_arrayref;
      $template->param('accounts',$acctref);
      $qrep = $dbh->prepare("SELECT categorycode,description FROM categories ORDER BY description");
      $qrep->execute;
      $template->param('categories',$qrep->fetchall_arrayref);
      if ($multibranch) {
        $qrep = $dbh->prepare("SELECT branchcode, branchname FROM branches ORDER BY branchname");
        $qrep->execute;
        $template->param('branchtbl',$qrep->fetchall_arrayref);
      }
      $qrep = $dbh->prepare("SELECT authorised_value, lib FROM ".
                            "borrower_attribute_types ".
                            "LEFT JOIN authorised_values ON (authorised_value_category = category) ".
                            "WHERE code = '$Attributes{select}'");
      $qrep->execute;
      $template->param('selectcodes',$qrep->fetchall_arrayref);
      $template->param('repdef',$repdef);
      $template->param('repid',$repid);
      $template->param('subaction',$subaction);
      #$template->param('dump',"repdef=".Dumper($repdef)."\naccounts".Dumper($acctref));
      $template->param('ipath',ipath());
      $template->param('action',$action);
      ($trace & 16) && $sttrace->execute($subaction,'repdef', fix_html(Dumper($repdef)));
      $template->param('message',$message);
      print $cgi->header;
      print $template->output;
    } else {
      $template = $self->get_template({ file => 'wtf.tt' });
      $template->param('message', "$action $subaction not defined");
      $template->param('ipath',ipath());
      $template->param('subaction',$subaction);
      $template->param('action',$action);
      print $cgi->header;
      print $template->output;
    }
  }
}

sub tool_system {
  my ( $self, $message,$snperm,$action,$subaction,$trace) = @_;
  my $cgi = $self->{'cgi'};
  my ($template,%perm,$sth,$records,$headers);
  my ($sysperms,%uperms,$name);
  foreach (split(',',$snperm)){
    $uperms{$_} = 1;
  }
  my $card   = scalar $cgi->param('card')   || '';
  my $snuser = scalar $cgi->param('snuser') || '';
  my $dbh = C4::Context->dbh;
  my $sttrace = $dbh->prepare("INSERT INTO bodatrace SET action=?,subaction=?,parm=?");
  ($trace & 32) && $sttrace->execute($action,$subaction,"Entered");
  
  ### Add new user from system_home;
  if ($subaction eq 'Add new user') {
    $name = $cgi->param('name');
    if (!$card && !$name) {
      $message = "You must specify a card or name to add a user";
      $subaction = 'System home';
    } elsif ($name && !$card) {
      my %cards = find_patron($name,$trace);
      my $numfound = scalar (keys %cards);
      if (!$numfound) {
        $message = "$name not found";
        $subaction = 'System home';
      } elsif ($numfound > 1) {
        $template = $self->get_template({file => 'patron_many.tt'});
        $template->param('cards',\%cards);
        $card = '';
      } else {
        ($card) = keys %cards;
      }
    }
    if ($card) {
      $snuser = ' ';
      my $borrower = &GetMemberDetails(0,$card);
      if (!$borrower) {
        $message = 'Card $card not found';
        $subaction = 'System home';
      } else {
        my $stadd = $dbh->prepare("INSERT INTO bodausers SET cardnumber=?, snuser=?");
        $snuser = $borrower->{userid};
        $snuser = $card unless $snuser;
        $stadd->execute($card,$snuser);
        $subaction = 'Update system user';
        ($trace & 32) && $sttrace->execute($action,$subaction,"User $card $snuser added");
      }
    }
  }
  ### User update from system_user.tt
  if ($subaction eq 'Update system user') {
    my $stup = $dbh->prepare("UPDATE bodausers SET permissions=? WHERE cardnumber=?");
    $sysperms = join(',',$cgi->param('nperms'));
    $stup->execute($sysperms,$card);
    $subaction = 'System home';
    ($trace & 32) && $sttrace->execute($action,$subaction,"User $snuser $card updated");


  ### Delete system user from system_user.tt
  } elsif ($subaction eq 'Delete system user') {
    my $stdel = $dbh->prepare("DELETE FROM bodausers WHERE cardnumber=?");
    $stdel->execute($card);
    $subaction = 'System home';
    ($trace & 32) && $sttrace->execute($action,$subaction,"User $snuser $card deleted");


  # update deductible flag and map_to fields in bodaaccts
  } elsif ($subaction eq 'Update accounts') {
    my $stacctup = $dbh->prepare("UPDATE bodaaccts SET incexp=?,map_to=?,deductible=? WHERE donacct=?");
    my @uaAccts = $cgi->param('account');
    my @uaIncexps  = $cgi->param('incexp');
    my @uaMap_tos  = $cgi->param('map_to');
    my (%uaAccounts,$uaAccount,$uaIncexp,$uaMap_to,$uaDed);
    for (my $i=0; $i<@uaAccts; $i++) {
      $uaAccounts{$uaAccts[$i]} = [$uaIncexps[$i],$uaMap_tos[$i],0];
    }
    my @uaDeds = $cgi->param('ded');
    foreach (@uaDeds) { $uaAccounts{$_}->[2] = 1;}
    
    foreach my $uaAcct (keys %uaAccounts) {
      $stacctup->execute(@{$uaAccounts{$uaAcct}},$uaAcct);
    }
    $subaction = 'Accounts';
    $message = "Accounts updated";
    
  } elsif ($subaction eq 'Update transfer columns') {
    $template = $self->get_template({ file => 'system_home.tt' });
    my @excelFields = ([qw(Address Address2 City State Zipcode Phone Email Memo Branch)],
                      [qw(Date Name Card_number Account Amount)]);
    my $excelUp = $dbh->prepare("UPDATE bodasystem SET value=? WHERE internal=? AND type='excel'");
    for (my $excelInt = 0; $excelInt < 2; $excelInt++) {
      my @excelNames = @{$excelFields[$excelInt]};
      my @excelCols = ();
      for my $excelName (@excelNames) {
        push @excelCols,uc(scalar $cgi->param($excelName));
      }
      $excelUp->execute(join(',',@excelCols),$excelInt);
      ($trace & 32) && $sttrace->execute($action,$subaction,"$excelInt ".join(',',@excelCols));
    }
    $subaction = 'System home';
    $message = "Excel columns updated";
  

  # show user for update  from system_home
  } elsif ($subaction eq 'User update') {
    $template = $self->get_template({ file => 'system_user.tt' });

    # get data for current user
    $sth = $dbh->prepare("SELECT cardnumber,snuser,permissions FROM bodausers WHERE cardnumber=?");
    $sth->execute($card);
    ($card,$snuser,$sysperms) = $sth->fetchrow_array;
    $sysperms = '' unless $sysperms;
    foreach (split(",",$sysperms)) {
      $uperms{$_} = 1;
    }
    $subaction = 'Update';
  }

  $sth = '';

  ### logs from system_home
  if ($subaction eq 'Report log') {
    $template = $self->get_template({ file => 'system_log.tt' });
    $sth = $dbh->prepare("SELECT repid ID,
                          report_name Report,
                          notes Description,
                          creator Creator,
                          DATE(date_created) Created,
                          modified_by Updater,
                          DATE(last_modified) Updated,
                          last_run Run FROM bodareports ORDER BY ID");
    $sth->execute();
  } elsif ($subaction eq 'Use log') {
    $template = $self->get_template({ file => 'system_log.tt' });
    $sth = $dbh->prepare("SELECT snuser User, loggedon Logged_On ".
                        "FROM bodalog ".
                        "WHERE loggedon >= SUBDATE(NOW(), INTERVAL 2 MONTH) ".
                        "ORDER BY loggedon desc");
  } elsif ($subaction eq 'Accounts') {
    $template = $self->get_template({ file => 'system_accts.tt' });
    $sth = $dbh->prepare("SELECT donacct Account, acctdesc Description, deductible DED, incexp Update_expiry, map_to ".
                          "FROM bodaaccts order by qb desc,donacct");
  
    
  } elsif ($subaction eq 'Transfer columns') {
    $template = $self->get_template({ file => 'system_Excel.tt' });
    my $stexcel = $dbh->prepare("SELECT name,internal,value FROM bodasystem WHERE type='excel'");
    $stexcel->execute;
    while (my($sysNames,$sysRequired,$sysCols) = $stexcel->fetchrow_array) {
      my @excelNames = split /,/,$sysNames;
      my @excelCols  = split /,/,$sysCols;
      my @excelFields;
      while (my $excelField = shift @excelNames) {
        push @excelFields,[$excelField, @excelCols?(shift @excelCols):'-'];
      }
      if ($sysRequired) {
        $template->param('requiredFields',\@excelFields);
      } else {
        $template->param('optionalFields',\@excelFields);
      }
    }
  } elsif ($subaction eq 'Miscellaneous constants') {
    $template = $self->get_template({ file => 'system_misc.tt' });
    my $stmisc = $dbh->prepare("SELECT name,value FROM bodasystem WHERE type=?");
    my (@miscBusinessFlags,%miscCategory,%miscAttribute,$miscName,$miscValue);
    
    $stmisc->execute('BusinessFlags');
    while (($miscName,$miscValue) = $stmisc->fetchrow_array) {
      push @miscBusinessFlags,$miscValue;
    }
    $template->param('BusinessFlags',\@miscBusinessFlags);
    ($trace & 32) && $sttrace->execute("System","Show flags",join(', ',@miscBusinessFlags));
    
    $stmisc->execute('category');
    while (($miscName,$miscValue) = $stmisc->fetchrow_array) {
      $miscCategory{$miscName} = $miscValue;
    }
    $template->param('category',\%miscCategory);
    my $miscOut = Dumper(\%miscCategory);
    ($trace & 32) && $sttrace->execute("System","Show category",$miscOut);
    
    $stmisc->execute('attribute');
    while (($miscName,$miscValue) = $stmisc->fetchrow_array) {
      $miscAttribute{$miscName} = $miscValue;
    }
    $template->param('attribute',\%miscAttribute);
    $miscOut = Dumper(\%miscAttribute);
    ($trace & 32) && $sttrace->execute("System","Show attributes",$miscOut);
    
    
  } elsif ($subaction eq 'Update miscellaneous constants') {
    $template = $self->get_template({ file => 'system_home.tt' });
    $dbh->do("DELETE FROM bodasystem WHERE type = 'BusinessFlags'");
    my @businessFlag = $cgi->param('bflag');
    my $upSystem = $dbh->prepare("INSERT INTO bodasystem SET name='business',internal='array',type='BusinessFlags',value=?");
    foreach my $bflag (@businessFlag) {
      $upSystem->execute($bflag) if $bflag;
    }
    $upSystem = $dbh->prepare("UPDATE bodasystem SET value=? WHERE name=? AND type=?");
    my @attributeNames = (qw( family mail publish select ));
    %Attributes = ();
    foreach my $attributeName (@attributeNames) {
      my $attributeValue = scalar $cgi->param($attributeName);
      $upSystem->execute($attributeValue,$attributeName,'attribute');
      $Attributes{$attributeName} = $attributeValue;
    }
    $upSystem->execute(scalar($cgi->param('catBUS')),'bus','category');
    $upSystem->execute(scalar($cgi->param('catIND')),'ind','category');
    $upSystem->execute(scalar($cgi->param('branch')),'branch','category');
    $message = 'Miscellaneous constants updated';
    $subaction = 'System home';
  }
  
  # System home from many places
  if ($subaction eq 'System home') {
    $template = $self->get_template({ file => 'system_home.tt' });
    $sth = $dbh->prepare("SELECT cardnumber,snuser,permissions FROM bodausers");
    $sth->execute;
    $records = $sth->fetchall_arrayref;
    $template->param('records',$records);
  }

  if ($sth) {
    $sth->execute;
    $template->param('headers',$sth->{NAME});
    $template->param('records',$sth->fetchall_arrayref);
  }

  if (!$template) {
    $template = $self->get_template({ file => 'wtf.tt' });
    $message = "System - $subaction not implemented";
  }
  $template->param('card',$card);
  $template->param('snuser',$snuser);
  $template->param('uperms',\%uperms);
  $template->param('subaction',$subaction);
  $template->param('action',$action);
  $template->param('message',$message);
  $template->param('ipath',ipath());
  print $cgi->header;
  print $template->output;
}

sub tool_trace {
  my ( $self, $message,$snperm,$action,$subaction,$trace) = @_;
  my $cgi = $self->{'cgi'};
  my $tsubaction = scalar $cgi->param('tsubaction');
  my ($template,%perm,$sth,$records,$headers);
  my $dbh = C4::Context->dbh;
  my $sttrace = $dbh->prepare("INSERT INTO bodatrace SET action=?,subaction=?,parm=?");
  ($trace & 128) && $sttrace->execute("trace",$tsubaction,"trace=$trace");
  my $newTrace = $trace;
  if ($tsubaction eq 'Stop') {
    $newTrace = 0;
  } elsif ($tsubaction eq 'Clear') {
    $dbh->do("TRUNCATE bodatrace");
    $sttrace->execute("Trace","Reset","");
  } elsif ($tsubaction eq 'Save') {
    my @traces = $cgi->param('traces');
    $sttrace->execute("trace",$tsubaction,"traces=".join(", ",@traces));
    $newTrace=0;
    if (@traces) {
      while (my $t = shift @traces) {
        $t += 0;
        $newTrace = $newTrace | $t;
      }
    }
  }
  $self->store_data({mytrace => $newTrace});
  $template = $self->get_template({ file => 'traces.tt' });
  my %tracesplit;
  for (my $i = 1; $i < 1025; $i *= 2) {
    if ($newTrace & $i) {
      $tracesplit{$i} = 'checked';
    } else {
      $tracesplit{$i} = ' ';
    }
  }
  my $qtrace = $dbh->prepare("SELECT * FROM bodatrace ORDER BY tid DESC");
  $qtrace->execute;
  $headers = $qtrace->{NAME};
  $records = $qtrace->fetchall_arrayref;
  if ($records) {
    $template->param('headers',$headers);
    $template->param('records',$records);
  }
  $template->param('action',scalar $cgi->param('action'));
  $template->param('taction',scalar $cgi->param('taction'));
  $template->param('message',$message);
  $template->param('subaction',scalar $cgi->param('subaction'));
  $template->param('ipath',ipath());
  $template->param('traces',\%tracesplit);
  $template->param('ipath',ipath());
  print $cgi->header();
  print $template->output();
}




#-------------------------------------
# *** Reports
#-------------------------------------
sub get_data {
  my ($query,$selectcodes,$excelFile,$trace) = @_;
  my ($headers,$records,$formats);     # return data
  my $dbh = C4::Context->dbh;
  my $sttrace = $dbh->prepare("INSERT INTO bodatrace SET action=?,subaction=?,parm=?");

  my $stq = $dbh->prepare($query);
  #my $sta = $dbh->prepare("SELECT code,attribute FROM borrower_attributes WHERE borrowernumber = ?");
  my $stp = $dbh->prepare("SELECT concat_ws('{}',cardnumber,firstname,surname,email) FROM borrowers WHERE cardnumber = ?");
  my (@codes,$attribute,$code,$publish,$mail,$borrowernumber,$partner,@partners,$pname,$pemail,$pcard,$family);
 # my $nocode = 'IND,FAM,BUS,OTHER,PR,STAFF,DON';
  my $format3 = "Don_Date,Expiry,Joined";
  my $format2 = "Total,Ded_Total,Non_Ded,Amount";
  my $format1 = "Card,$Attributes{family}";

  $stq->execute;
  if (!$stq) {
    return (undef,undef,undef);
  }
  #
  #  Setup excel file
  #
  $excelFile = C4::Context->config('pluginsdir')."/Koha/Plugin/DonorApp/uploads/".$excelFile;
  unlink $excelFile if (-e $excelFile);
  my $workbook = Excel::Writer::XLSX->new($excelFile);
  my $worksheet = $workbook->add_worksheet();
  $worksheet->keep_leading_zeros();
  my $headFormat =$workbook->add_format();
  $headFormat->set_bold();
  my $dateFormat = $workbook->add_format();
  $dateFormat->set_num_format('mm/dd/yy');
  my $numFormat  = $workbook->add_format();
  $numFormat->set_num_format('#,###,##0.00');
  #my $textFormat = $workbook->add_format(num_format => '0');
  my $xrow = 0;
  my $xcol = 0;

  $headers = $stq->{NAME};
  push @$headers,$Attributes{select} if $Attributes{select};
  push @$headers,$Attributes{mail} if $Attributes{mail};
  push @$headers,$Attributes{publish} if $Attributes{publish};
  push @$headers,(qw/ Partner Name Email/) if $Attributes{family};
  shift @$headers;                            # drop borrowernumber header
  my $columnCount = scalar(@$headers) -4;
  my @blankrow;
  for (my $i=0;$i < $columnCount; $i++) {
    push @blankrow,' ';
  }
  my ($colname, $column, @row);
  for ($column=0; $column<@$headers; $column++) {
    if ($format1 =~ m/$headers->[$column]/) {
      $formats->[$column] = 1;
    } elsif ($format2 =~ m/$headers->[$column]/) {
      $formats->[$column] = 2;
    } elsif ($format3 =~ m/$headers->[$column]/) {
      $formats->[$column] = 3;
    } else {
      $formats->[$column] = 0;
    }
    $worksheet->write(0,$column,$headers->[$column],$headFormat);
  }

  # Excel file main loop
  
  while (@row = $stq->fetchrow_array) {
    $borrowernumber = shift @row;
  #  $sta->execute($borrowernumber);
    @partners=();
    @codes=();
    $mail = "N/S";
    $publish = "N/S";
    my $attributes = C4::Members::Attributes::GetBorrowerAttributes($borrowernumber);
    foreach $attribute (@$attributes) {
      $code = $attribute->{code};
      if ($code eq $Attributes{mail}) {
        $mail = ($attribute->{value})?'OK ':'NOT OK';
      } elsif ($code eq $Attributes{publish}) {
        $publish = ($attribute->{value})?'OK ':'NOT OK';
      } elsif ($code eq $Attributes{select}) {
        push @codes,$attribute->{value};
      } elsif ($code eq $Attributes{family}) {
        $pcard = $attribute->{value};
        $family = &GetMemberDetails(0,$pcard);
        if (!$family) {
          push @partners,[$pcard,"is not a valid card number","Please fix it"];
        } else {
          push @partners,[$family->{cardnumber},join(' ',$family->{firstname}||'',$family->{surname}),$family->{email}];
        }
      }
    }
    
    if (@codes > 0) {
      $code = join(', ',@codes);
    } else {
      $code = ' ';
    }
    push @row,$code if ($Attributes{select}); 
    push @row,$mail if ($Attributes{mail}); 
    push @row,$publish if ($Attributes{publish}); 
    
    if ($Attributes{family} && (@partners > 0)) {
      foreach $partner (@partners) {
        ($pcard,$pname,$pemail) = @$partner;
        push @row,$pcard,$pname,$pemail;
        push @$records,[@row];
        $xrow++;
        for ($xcol=0; $xcol<@row; $xcol++) {
          if ($formats->[$xcol] == 2) { $worksheet->write($xrow,$xcol,$row[$xcol],$numFormat); }
          elsif ($formats->[$xcol] == 3) { $worksheet->write_date_time($xrow,$xcol,$row[$xcol].'T',$dateFormat); }
          else { $worksheet->write_string($xrow,$xcol,$row[$xcol]); }
        }
        @row = ($row[0],@blankrow);
      }
    } else {
      push @$records,[@row];
      $xrow++;
      for ($xcol=0; $xcol<@row; $xcol++) {
        if ($formats->[$xcol] == 2) { $worksheet->write($xrow,$xcol,$row[$xcol],$numFormat); }
        elsif (($formats->[$xcol] == 3) && $row[$xcol]) { $worksheet->write_date_time($xrow,$xcol,$row[$xcol].'T',$dateFormat); }
        else { $worksheet->write($xrow,$xcol,$row[$xcol]); }
      }
    }
  }
 
  $workbook->close();
  return ($headers,$records,$formats);
}

sub set_repdef {
  my ($cgi, $trace) = @_;
  my ($repdef);
  $repdef->{report_name}= scalar $cgi->param('report_name');
  $repdef->{notes}      = scalar $cgi->param('notes');
  $repdef->{expfrom}    = get_date(scalar $cgi->param('expfrom')) || '';
  $repdef->{expto}      = get_date(scalar $cgi->param('expto')) || '';
  $repdef->{zipfrom}    = (scalar $cgi->param('zipfrom')) || '';
  $repdef->{zipto}      = (scalar $cgi->param('zipto')) || '';
  $repdef->{email}      = scalar $cgi->param('email');
  $repdef->{lowamt}     = scalar $cgi->param('lowamt');
  $repdef->{highamt}    = scalar $cgi->param('highamt');
  $repdef->{tottype}    = scalar $cgi->param('tottype');
  $repdef->{orderby}    = scalar $cgi->param('orderby') || 'card';
  $repdef->{donfrom}    = get_date(scalar $cgi->param('donfrom')) || '';
  $repdef->{donto}      = get_date(scalar $cgi->param('donto')) || '';
  $repdef->{acctlim}    = (join(',',$cgi->param('acctlim')));
  $repdef->{selcodes}   = (join(',',$cgi->param('selcodes')));
  $repdef->{catcodes}   = (join(',',$cgi->param('catcodes')));
  $repdef->{branches}   = (join(',',$cgi->param('branches'))) if $multibranch;
  $repdef->{field}      = (join(',',$cgi->param('field')));
  $repdef->{searchdesc} = scalar $cgi->param('searchdesc') || '';
  return $repdef;
}

sub save_report {
  my ($cgi, $repid, $subaction, $snuser, $trace) = @_;
  my $message;
  my $repdef = set_repdef($cgi,$trace);
  my (@where,@having,$dateField,$dateValue);
  my $query = 'SELECT b.borrowernumber, b.cardnumber Card, cc.description Category ';
  my $tottype = $repdef->{tottype};
  my $orderby = $repdef->{orderby};
  my $joinAccounts = 0;
  my $joinAttributes = 0;
  my $joinBranches = $multibranch;
  my $dbh = C4::Context->dbh;
  my $sttrace = $dbh->prepare("INSERT INTO bodatrace SET action=?,subaction=?,parm=?");

  my %fields = ( Full_Name => [1,0,"concat_ws(' ',title,firstname,surname)"],
                 First_Name=> [2,1,"firstname"],
                 Surname   => [3,1,"surname"],
                 Address1  => [4,1,"concat_ws(' ',streetnumber,address,streettype)"],
                 Address2  => [5,1,"address2"],
                 City      => [6,1,"city"],
                 State     => [7,1,"state"],
                 ZIP       => [8,1,"zipcode"],
                 CityStZip => [9,0,"concat_ws(' ',city,state,zipcode)"],
                 Phone     => [10,1,"phone"],
                 Cell      => [11,0,"mobile"],
                 Email     => [12,1,"email"],
                 Expiry    => [13,1,"dateexpiry"],
                 Joined    => [14,0,"dateenrolled"],
                 Branch    => [15,1,"bc.branchname"],
  );
  my %qb2pt;
  my $map = $dbh->prepare("SELECT donacct,map_to FROM bodaaccts WHERE map_to IS NOT NULL");
  $map->execute;
  while (my($donacct,$map_to) = $map->fetchrow_array) {
    push @{$qb2pt{$map_to}},$donacct;
  }

  my @showFields = split /,/,$repdef->{field};
  foreach my $field (@showFields) {
    $query .= ', '.${$fields{$field}}[2].' '.$field;
  }

  push @where,"zipcode >= '$repdef->{zipfrom}'"    if $repdef->{zipfrom};
  push @where,"zipcode <= '$repdef->{zipto}'"      if $repdef->{zipto};
  push @where,"dondate >= '$repdef->{donfrom}'"    if $repdef->{donfrom};
  push @where,"dondate <= '$repdef->{donto}'"      if $repdef->{donto};
  push @where,"dateexpiry >= '$repdef->{expfrom}'" if $repdef->{expfrom};
  push @where,"dateexpiry <= '$repdef->{expto}'"   if $repdef->{expto};


  if ($repdef->{lowamt}) {
    if ($tottype eq 'total') {
      push @having,"Ded_Total >= ".$repdef->{lowamt};
    } else  {
      push @where,"donamt >= ".$repdef->{lowamt};
    }
    $joinAccounts = 1;
  }

  if ($repdef->{highamt}) {
    if ($tottype eq 'total') {
      push @having,"Ded_Total <= ".$repdef->{highamt};
    } else  {
      push @where,"donamt <= ".$repdef->{highamt};
    }
    $joinAccounts = 1;
  }

  # Search description & jobid
  if ($repdef->{searchdesc}) {
    $query .= ", concat_ws(' ',d.jobid,d.description) Search";
    push @where,"( d.jobid LIKE '\%".$repdef->{searchdesc}."\%' OR ".
                "d.description LIKE '\%".$repdef->{searchdesc}."\%')";
  }

  # Email required or not present
  if ($repdef->{email}) {
    if ($repdef->{email} eq 'must') {
      push @where,"(email != ' ' AND email IS NOT NULL)";
    } elsif ($repdef->{email} eq 'not') {
      push @where,"(email = ' ' OR email IS NULL)";
    }
  }

  # Account restrictions
  if ($repdef->{acctlim}) {
    my @acctlims = split /,/,$repdef->{acctlim};
    my (@whereAcct,$lacct,$ptacct);
    foreach $lacct (@acctlims) {
      push @whereAcct,"a.donacct = '$lacct'";
      if (exists $qb2pt{$lacct}) {
        foreach $ptacct (@{$qb2pt{$lacct}}) {
          push @whereAcct,"a.donacct = '$ptacct'";
        }
      }
    }
    push @where,"(".join(' OR ',@whereAcct).")";
    $joinAccounts = 1;
  }

  # Restrict categories
  my (@whereCat,$lcat);
  if ($repdef->{catcodes}) {
    my @catcodes = split /,/,$repdef->{catcodes};
    foreach $lcat (@catcodes) {
      push @whereCat,"b.categorycode = '$lcat'";
    }
    push @where,"(".join(' OR ',@whereCat).")";
  }

  # Restrict branches
  if ($multibranch) {
    my (@whereBranch,$lbranch);
    if ($repdef->{branches}) {
      my @branchcodes = split /,/,$repdef->{branches};
      foreach $lbranch (@branchcodes) {
        push @whereBranch,"b.branchcode = '$lbranch'";
      }
      push @where,"(".join(' OR ',@whereBranch).")";
    }
  }

  # Restrict selcodes
  my (@whereSel,$lsel);
  if ($repdef->{selcodes}) {
    my @selcodes = split /,/,$repdef->{selcodes};
    foreach $lsel (@selcodes) {
      push @whereSel,"ba.code = 'SELECT' AND attribute='$lsel'";
    }
    push @where,"(".join(' OR ',@whereSel).")";
    $joinAttributes = 1;
  }

  # add the total fields
  if ($tottype eq 'total') {
    $query .= ", SUM(donamt) Total, SUM(donamt * deductible) Ded_Total, SUM(donamt * (1-deductible)) Non_Ded ";
    $joinAccounts = 1;
  } elsif ($tottype eq 'individual') {
    $query .= ', donamt Amount, dondate Don_Date, d.donacct Account ';
    $joinAccounts = 1;
  }


  if ($joinAttributes) {
    $query .= " FROM borrower_attributes ba LEFT JOIN borrowers b on (ba.borrowernumber = b.borrowernumber) ";
  } else {
    $query .= " FROM borrowers b ";
  }

  if ($joinAccounts) {
    $query .= " LEFT JOIN bodadonations d ON (b.cardnumber = d.cardnumber) ".
    " LEFT JOIN bodaaccts a ON (d.donacct = a.donacct) ";
  }
  if ($joinBranches) {
    $query .= "LEFT JOIN branches bc ON (b.branchcode = bc.branchcode) ";
  }
  $query .= "LEFT JOIN categories cc ON (b.categorycode = cc.categorycode) ";
  # Any selection conditions
  if (@where > 0) {
    $query .= " WHERE ".join(' AND ',@where);
  }

  if ($tottype eq 'total') {
    $query .= " GROUP BY b.cardnumber ";
    if (@having > 0) {
      $query .= " HAVING ".join(' AND ',@having);
    }
  }
  if ($orderby eq 'total') {
    if ($tottype eq 'total') {
      $query .= ' ORDER BY DED_Total desc';
    } elsif ($tottype eq 'individual') {
      $query .= ' ORDER BY Amount desc';
    } else {
      $query .= ' ORDER BY b.cardnumber';
      $message .= " order by defaults to cardnumber with show donations = 'none'";
    }
  } elsif ($orderby eq 'surname') {
    $query .= ' order by b.surname';
  } elsif ($orderby eq 'zip') {
    $query .= ' order by b.zipcode';
  } else {
    $query .= ' order by b.cardnumber';
  }

  $repdef->{savedsql} = fix_html($query);
  ($trace & 8) && $sttrace->execute("saved_sql",$subaction,fix_html($query));
  $repdef->{notes} = fix_html($repdef->{notes});

  my $saveQuery = " SET ";
  delete($repdef->{repid});
  foreach my $field (keys %$repdef) {
    if (!$repdef->{$field} || ($repdef->{$field} eq '')) {
      $saveQuery .= " $field = NULL,";
    } else {
      $saveQuery .= " $field = '".$repdef->{$field}."',";
    }
  }


  if ($subaction eq 'Save') {
    $dbh->do("INSERT INTO bodareports ".$saveQuery." creator='$snuser', date_created=NOW()");
    $repid = $dbh->last_insert_id(undef,undef,undef,undef);
  } else {
    $dbh->do("UPDATE bodareports ".$saveQuery." modified_by='$snuser', last_modified=NOW() WHERE repid='$repid'");
  }
  ($trace & 8) && $sttrace->execute("Update bodareports","$subaction $repid",$saveQuery);
  if ($dbh->err) {
    $message .= $dbh->errstr."<br />";
  }
  return ($repid, $message);
}

sub patron_attributes {
  my ($borrower,$trace) = @_;
  my $bnumber = $borrower->{borrowernumber};
  my ($code,$attributes,$attribute,$pcard,$pname,$family);
  my $partner = '';
  my $codes = '';
  my @pdata = ();
  $attributes = C4::Members::Attributes::GetBorrowerAttributes($bnumber);
  foreach $attribute (@$attributes) {
    $code = $attribute->{code};
    if ($code eq $Attributes{mail}) {
      $borrower->{mail} = ($attribute->{value})?'OK ':'NOT OK';
    } elsif ($code eq $Attributes{publish}) {
      $borrower->{publish} = ($attribute->{value})?'OK ':'NOT OK';
    } elsif ($code eq $Attributes{select}) {
      $codes .= "$attribute->{value} ";
    } elsif ($code eq $Attributes{family}) {
      $pcard = $attribute->{value};
      $family = &GetMemberDetails(0,$pcard);
      if (!$family) {
        push @pdata,"$pcard is not a valid card number";
      } else {
        push @pdata,"<input type='submit' name='card' value='$pcard' />$family->{firstname} $family->{surname}";
      }
    }
  }
  if ($codes) {
    $borrower->{selectcodes} = $codes;
  }
  if (@pdata) {
    $borrower->{family} = join("<br />",@pdata);
  }
  if ($multibranch) {
    $borrower->{branchcode} = $Branches{$borrower->{branchcode}};
  } else {
    delete $borrower->{branchcode};
  }
  $borrower->{categorycode} = $Categories{$borrower->{categorycode}};
  $borrower->{multibranch} = $multibranch;
  return $borrower;
}



sub get_date {
  my $dt = shift;
  if (!$dt) { return '';}
  my $cdt = UnixDate($dt,"%Y-%m-%d");
  if ($cdt) { return $cdt;}
  return '';
}

#-------------------------------------
# *** Upload Accounting Data
#-------------------------------------
sub upload_qb {
  my ($xlsxin, $trace) = @_;
  my ($message,$drange,$updatedPatrons,$badFunds,$acctTotals); # return these
  # drange         = [minDate,maxDate,numberdeleted]
  # updatedPatrons = [[card,name,address,change_description]]
  # badFunds       = [fund name]
  # acctTotals     = { account number => [description,total,deductible,level]}

  # Excel input fields
  my ($donaddress1,$donaddress2,$donfund,$fundcard);
  my @blanks;
  for (my $i = 0; $i < 13; $i++) {$blanks[$i]='';}
  my ($dondate,$donname,$donstr1,$donstr2,$doncity,$donstate,
      $donphone,$donemail,$doncard,$donmemo,$donacct,$donamt,$donbranch) = @blanks;
  my $donzip = '00000';
  $donbranch=$Categories{branch} if $Categories{branch};

  my ($coldate,$colname,$colstr1,$colstr2,$colcity,$colstate,$colzip,
      $colphone,$colemail,$colcard,$colmemo,$colacct,$colamt,$colbranch);

  my $datetime;
  my $minDate = 9999999999999999;
  my $maxDate = -1;
  # Koha fields
  my ($firstname,$surname,$address1,$address2);
  my ($addressScore,$comment,$newExpiry);
  my ($donfulladdress, $fulladdress,$categorycode);
  my ($borrower,$borrowernumber);
  my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
  
  get_businessFlag();
  
  # Koha shortcut for new cards and changed addresses
  my %newCard;            # $donname => $cardnumber
  my %newAddress;         # $doncard => 1

  # Account fields
  my $grandTotal = 0;
  my $donationCount = 0;
  my (%acctTotals, $acctdesc, $acct);

  # Connect to mysql
  my $dbh = C4::Context->dbh;
  #---
  # Get columns
  #---
  my $sth = $dbh->prepare("SELECT internal,value FROM bodasystem WHERE type='excel'");
  $sth->execute;
  
  while (my($bodaInternal,$bodaValue) = $sth->fetchrow_array) {
    if ($bodaInternal) {
      ($coldate,$colname,$colcard,$colacct,$colamt) = number_the_columns(split /,/,$bodaValue);
    } else {
      ($colstr1,$colstr2,$colcity,$colstate,$colzip,$colphone,$colemail,$colmemo,$colbranch) = 
        number_the_columns(split /,/,$bodaValue);
    }
  }

  #----
  # Get category/branch codes
  #----
  $sth = $dbh->prepare("SELECT name,value FROM bodasystem WHERE type='category'");
  $sth->execute;
  while (my ($catName,$catValue) = $sth->fetchrow_array) {
    $Categories{$catName} = $catValue;
  }

  #-------------------
  # Open the Spreadsheet and get the second sheet
  #------------=------


  my $book = ReadData($xlsxin);
  if (!$book) {
    return ("$xlsxin failed to open as an Excel file",undef,undef,undef,undef);
  }
  my $sheets = $book->[0]->{sheets} || 1;
  my $type   = $book->[0]->{type};
  $type = 'xlsx' if $type eq 'xls';
  my $xlsx = ($type eq 'xlsx');
  
  while (!$book->[$sheets]->{maxcol}) {
    $sheets--;
    return ("Can't find a data sheet in $xlsxin",undef,undef,undef,undef) unless $sheets;
  }
  my $sheet  = $book->[$sheets];
  my $maxcol = $sheet->{maxcol};
  my $maxrow = $sheet->{maxrow};
  my $cells  = $sheet->{cell};

  #--------------------------
  # Prepare SQL
  #--------------------------
  my $qdon = $dbh->prepare("INSERT INTO bodadonations SET cardnumber=?,fund=?,dondate=?,donamt=?,".
                           "donacct=?, description=?");
  my $qact = $dbh->prepare("INSERT INTO bodaaccts SET donacct=?, acctdesc=?, deductible=1, level=1");
  my $sttrace = $dbh->prepare("INSERT INTO bodatrace SET action=?,subaction=?,parm=?");
  my $bfinsert = $dbh->prepare("INSERT INTO bodafunds SET QBname=?, fundcard=?");

  ($trace & 64) && $sttrace->execute("Upload","Entered","$maxrow rows");

  #-------------------------------------------------------
  # find date range and delete all donations in that range
  #-------------------------------------------------------
  for (my $row=2; $row<$maxrow; $row++) {
    $dondate   = $cells->[$coldate]->[$row];
    $dondate = UnixDate($dondate,"%s") unless $xlsx;
    if ($dondate) {
      if ($dondate > $maxDate) { $maxDate = $dondate;}
      if ($dondate < $minDate) { $minDate = $dondate;}
    }
  }
  if ($xlsx) {
    $drange->[0] = DateTime::Format::Excel->parse_datetime($minDate)->ymd;
    $drange->[1] = DateTime::Format::Excel->parse_datetime($maxDate)->ymd;
  } else {
    $drange->[0] = UnixDate("epoch $minDate","%Y-%m-%d");
    $drange->[1] = UnixDate("epoch $maxDate","%Y-%m-%d");
  }
  ($trace & 64) && $sttrace->execute("Upload","Date Range",join (', ',@$drange));
  my $row = $dbh->do("DELETE FROM bodadonations WHERE dondate <= '$drange->[1]' AND dondate >= '$drange->[0]'");
  if ($row ne '0E0') {
    $drange->[2] = $row;
  } else {
    $drange->[2] = 0;
  }
  ($trace & 64) && $sttrace->execute("Upload","Deleted","drange=(".join(', ',@$drange).")");
  #-----------------------------------------
  # Setup account numbers names and totals
  #-----------------------------------------
  $sth = $dbh->prepare("SELECT * FROM bodaaccts where qb=1");
  $sth->execute();
  my $acctrow;
  while($acctrow = $sth->fetchrow_hashref()) {
    $donacct = trim($acctrow->{donacct});
    $acctTotals->{$donacct} = [$acctrow->{acctdesc},0,$acctrow->{deductible},$acctrow->{level},$acctrow->{expinc}];
  }
  ($trace & 64) && $sttrace->execute("Upload","Accounts",join(', ',(sort keys %$acctTotals)));
  #------------------------------
  # Get fund cards and aliases
  #------------------------------
  $sth = $dbh->prepare("SELECT surname,cardnumber FROM borrowers WHERE categorycode='FUND'");
  my %fundAlias;
  $sth->execute;
  while (($donfund,$doncard) = $sth->fetchrow_array) {
    $fundAlias{$donfund} = $doncard;
  }
  $sth = $dbh->prepare("SELECT QBname,fundcard FROM bodafunds");
  $sth->execute;
  while (($donfund,$doncard) = $sth->fetchrow_array) {
    $fundAlias{$donfund} = $doncard;
  }
  $sth = $dbh->prepare("SELECT MAX(fundcard) FROM bodafunds WHERE fundcard like 'bf%'");
  $sth->execute;
  ($badFunds) = $sth->fetchrow_array;
  if (!$badFunds) { $badFunds = 0;}
  else { $badFunds = substr($badFunds,2) + 1;}
  ($trace & 64) && $sttrace->execute("Upload","fundAlias",fix_html(Dumper(%fundAlias)));
  #----------------------------
  # Import Main loop
  #----------------------------
  for (my $c = 1; $c <= $maxcol; $c++) {
    my $value = $cells->[$c]->[3];
    next unless $value;
    ($trace & 64) && $sttrace->execute("Upload","columns", "$c (".number2column($c).") = '$value'");
  }
  

  for (my $row=2; $row <= $maxrow; $row++) {
    $comment   = '';
    $donacct   = $cells->[$colacct]->[$row] || '';
    if ($donacct =~ m/\s*(\S+)\s+\S{0,2}\s*(\S.+)\s*$/) {
      $acct = $1;
      $acctdesc = $2;
    } else {
      $acct = $donacct;
      $acctdesc = '';
    }
    ($trace & 64) && $sttrace->execute("Upload","Account","'$donacct' '$acct' '$acctdesc' from $colacct");
    next unless $acct;
    $donamt    = $cells->[$colamt]->[$row] || '';
    ($trace & 64) && $sttrace->execute("Upload","Amount","'$donamt' from $colamt");
    next unless $donamt;
    $donamt    =~ s/,//;         #pesky commas in csv formatted files
    $dondate   = $cells->[$coldate]->[$row];
    if ($xlsx) {
      $dondate = DateTime::Format::Excel->parse_datetime($dondate)->ymd;
    } else {
      $dondate = UnixDate($dondate,"%Y-%m-%d");
    }
    ($trace & 64) && $sttrace->execute("Upload","Date","'$dondate' from $coldate");
    next unless $dondate;
    $donname   = $cells->[$colname]->[$row] || '';
    $donname   =~ s/\&amp\;/\&/g;
    $doncard   = $cells->[$colcard]->[$row];

    $donstr1   = ($cells->[$colstr1]->[$row] || '') unless $colstr1 eq '-';
    $donstr2   = ($cells->[$colstr2]->[$row] || '') unless $colstr2 eq '-';
    $doncity   = ($cells->[$colcity]->[$row] || '') unless $colcity eq '-';
    $donstate  = ($cells->[$colstate]->[$row] || '') unless $colstate eq '-';
    $donzip    = ($cells->[$colzip]->[$row] || '') unless $colzip eq '-';
    $donphone  = ($cells->[$colphone]->[$row] || '') unless $colphone eq '-';
    $donemail  = ($cells->[$colemail]->[$row] || '') unless $colemail eq '-';
    $donmemo   = ($cells->[$colmemo]->[$row] || '') unless $colmemo eq '-';
    $donbranch = ($cells->[$colbranch]->[$row] || '') unless $colbranch eq '-';
    # skip blank lines
    $fundcard = '';
    if ($donname =~ m/(.+)\:(.+)/) {    # We have a fund
      $donname = trim($1);
      $donfund = trim($2);

      if (exists $fundAlias{$donfund}) {
        $fundcard = $fundAlias{$donfund};
      } elsif (isFund($donfund)) {
        $badFunds++;
        $fundcard = sprintf("bf%04d",$badFunds);
        $fundAlias{$donfund} = $fundcard;
        $bfinsert->execute($donfund,$fundcard);
        ($trace & 256) && $sttrace->execute("Upload","bad fund","$donfund -> $fundcard row $row" );
      }

      ($trace & 256) && $sttrace->execute("Upload","fund","($row) $donname - $doncard, $donfund - $fundcard $donamt $acct, row $row");

    }
    # get address
    $donaddress1 = $donstr1;
    $donaddress2 = '';
    if ($donstr1 =~ m/^\s*\d/) {
      $donaddress2 = $donstr2;
    } elsif ($donstr2) {
      $donaddress1 = $donstr2;
    }
    $donaddress1 = ' ' unless $donaddress1;

    if (!$donname) {
      $donname = "Unknown Donor";
    }

    # Add new account
    if ($donacct =~ m/\s*(\S+)\s*.\s*(.*)\s*$/) {
      $acct = $1;
      $acctdesc = $2;
    } elsif ($donacct =~ m/\s*(\S+)\s+(.*)\s*$/) {
      $acct = $1;
      $acctdesc = $2;
    } else {
      $acct = trim(substr($donacct,0,5));
      $acctdesc = trim(substr($donacct,8));
    }
    if (exists($acctTotals->{$acct})) {
      $acctTotals->{$acct}->[1] += $donamt;
    } else {
      $acctTotals->{$acct} = [$acctdesc,$donamt,1,1,0];
      $qact->execute($acct,$acctdesc);
      ($trace & 64) && $sttrace->execute("Upload","Accounts","($row) Added <$acct> <$acctdesc>");
    }

    # check card number
    if (!$doncard) {
      # Have we found it before?
      if (exists($newCard{$donname})) {
        $doncard = $newCard{$donname};
      } else {
        # No go look for it
        my $nameFound;
        ($doncard,$nameFound) = get_card($donname,$donaddress1,$donaddress2,$doncity,$donstate,
                                          $donzip,$dondate,$donbranch,$trace);
        $newCard{$donname} = $doncard;
        if (!$doncard) {
          push @$updatedPatrons,['N.F.',$donname,$donaddress1,"Could not be added"];
          next;
        }
        push @$updatedPatrons,[$doncard,$donname,$donaddress1,"$nameFound - Update QB"];
      }
    }
    # Get the borrower record;
    $borrower = &GetMemberDetails(0,$doncard);
    if ($borrower) {
      $borrowernumber = $borrower->{borrowernumber};
    } else {
      ($trace & 64) && $sttrace->execute("Upload","No borrower","$doncard, $donname");
      next;
    }
    # Check Address change
    if (!exists $newAddress{$doncard}) { # check it
      $address1 = $borrower->{address};
      if (!$donaddress1 || ($donaddress1 =~ m/^\s*$/)) {      # address missing in QB
        if ($address1 && ($address1 !~ m/^\s*$/)) {           # address present in database
          push @$updatedPatrons,[$doncard,$donname,$address1,"Address missing in QB"];
        }                                                     # else both are missing
      } else {                                                # address present in QB
        $addressScore = similarity $donaddress1,$address1;
        ($trace & 64) && $sttrace->execute("Upload","address check","($row) $doncard '$donaddress1' '$address1' $addressScore");
        if ($addressScore < .70) {       # They are different

          if (ModMember(borrowernumber=>$borrowernumber, address=>$donaddress1, address2=>$donaddress2,
                        city=>$doncity, state=>$donstate, zipcode=>$donzip)) {
            push @$updatedPatrons,[$doncard,$donname,"$address1 -> $donaddress1","Address updated"];
          } else {
            push @$updatedPatrons,[$doncard,$donname,$donaddress1,"Address update failed"];
          }
        }                                                     # else address OK
      }
      $newAddress{$doncard} = 1;    # don't try again
    }
    # Update donation
    $donmemo = trim($donmemo);
    ($trace & 64) && $sttrace->execute("Upload","add Donation","($row) $fundcard,$doncard,$dondate,$donamt,$acct,$donmemo");
    $qdon->execute($doncard,$fundcard,$dondate,$donamt,$acct,$donmemo);
    if ($fundcard) {
      $qdon->execute($fundcard,$doncard,$dondate,$donamt,$acct,$donmemo);
    }
    $donationCount++;

    #check for extending the expiry date
    my $expiryAcct = $acctTotals->{$acct}->[4];
    if ($expiryAcct && ($donamt >= $expiryAcct)) {
      $dondate =~ m/(\d\d\d\d)-(\d\d)/;
      $newExpiry = UnixDate("last day of ".$months[$2-1]." in ".($1+1),"%Y-%m-%d");
      if ($newExpiry gt $borrower->{dateexpiry}) {
        $categorycode = $borrower->{categorycode};
        if ($categorycode eq 'OTHER') {
          if (($address1 !~ /^\s*\d/) && $address2) {
            $categorycode = 'FAM';
          } else {
            $categorycode = 'IND';
          }
        }
        if (!ModMember(borrowernumber=>$borrowernumber,categorycode=>$categorycode,dateexpiry=>$newExpiry)) {
          push @$updatedPatrons,[$doncard,$donname," ","Expiry Date $newExpiry not updated"];
        } else {
          push @$updatedPatrons,[$doncard,$donname," ","Expiry Date $newExpiry updated"];
        }
      }
    }
  }

  #----------------
  # End Main Loop
  #----------------
  my $acctOut;
  foreach $acct (keys %$acctTotals) {
    if ($acctTotals->{$acct}->[1]) {      # non-zero total
      $acctOut->{$acct} = $acctTotals->{$acct};
      if ($acctTotals->{$acct}->[2]) {     # deductible
        $grandTotal += $acctTotals->{$acct}->[1];
      }
      $acctOut->{$acct}->[1] = commify($acctOut->{$acct}->[1]);
    }
  }
  $acctOut->{Grand} = ["Total",commify($grandTotal),1,0];
  #-----------
  # All done
  #-----------

 # ($trace & 64) && $sttrace->execute("Upload","updatedPatrons",Dumper($updatedPatrons) );
 # ($trace & 64) && $sttrace->execute("Upload","badFunds",Dumper($badFunds) );
  ($trace & 64) && $sttrace->execute("Upload","acctOut",Dumper($acctOut) );
  return ($message,$drange,$updatedPatrons,$badFunds,$acctOut);
  sub isFund {
    my @notAfund = (qw/none unknown anonymous/);
    my $f = shift;
    foreach (@notAfund) {
      return 0 if $f =~ m/$_/i;
    }
    return 1;
  }


}

sub get_card {
  my ($patron,$address1,$address2,$city,$state,$zipcode,$dondate,$donbranch,$trace) = @_;
  my %cards = find_patron($patron,$trace);
  my ($kcard,%borrower,$kaddress);
  my $dbh = C4::Context->dbh;
  my $sttrace = $dbh->prepare("INSERT INTO bodatrace SET action=?,subaction=?,parm=?");
  ($trace & 2) && $sttrace->execute('get_card',"for $patron","got ".scalar %cards." cards");
  $address1 = trim($address1);
  foreach $kcard (sort {$cards{$a}->{score} cmp $cards{$b}->{score}} keys %cards) {
    $kaddress = trim($cards{$kcard}->{address});
    if (!$address1 || !$kaddress || ((similarity($address1, $kaddress)) > .75)) {
      return ($kcard,'Found');
    }
  }
  # No match, create one
  my ($firstname,$surname,$suffix) = split_name($patron);
  my $categorycode = ($firstname)?$Categories{ind}:$Categories{bus};
  $address1 = ' ' unless $address1;
  $zipcode = '00000' unless $zipcode;
  $city = ' ' unless $city;
  $state = ' ' unless $state;
  my $cardnumber = fixup_cardnumber(' ');
  $surname .= " $suffix" if $suffix;
  %borrower = (firstname=>$firstname, surname=>$surname, address=>$address1,
               cardnumber=>$cardnumber, address2=>$address2, city=>$city,
               state=>$state,zipcode=>$zipcode,categorycode=>$categorycode,
               dateenrolled=>$dondate,dateexpired=>$dondate,branchcode=>$donbranch,privacy=>1);
  my $borrowernumber = AddMember(%borrower);
  if (!$borrowernumber) {
    return 0;
  }
  return ($cardnumber,'Added');
}



#-------------------------------------
# *** Configuration
#-------------------------------------


sub configure {
  my ( $self, $args ) = @_;
  my $cgi = $self->{cgi};
  my $ipath = ipath();
  my ($template,$message);
  my $dbh = C4::Context->dbh;
  my $trace = $self->retrieve_data('mytrace') || 1024;
  my $sttrace = $dbh->prepare("INSERT INTO bodatrace SET action=?,subaction=?,parm=?");
  my $action = scalar $cgi->param('action') || 'Home';
  $action = 'Create tables' unless configured();
  $self->go_home() if $action eq 'Done';
  $template = $self->get_template({file =>'configure_home.tt'});
  
  #
  # Create the tables and insert one user
  #
  if ($action eq 'Create tables') {
    my $borrowernumber = C4::Context->userenv->{number};
    my $borrower = GetMemberDetails($borrowernumber,0);
    my $card = $borrower->{cardnumber};
    my $name = $borrower->{userid};
    $name = $borrower->{firstname} unless $name;
    do_mysql_source($self,$ipath."/boda-table-create.sql",$trace);
    if (configured()) {
      do_mysql_source($self,$ipath."/boda-system.sql",$trace);
      do_mysql_source($self,$ipath."/boda-accts.sql",$trace);
      my $sth = $dbh->prepare("INSERT INTO bodausers SET cardnumber=?,snuser=?,permissions=?");
      my $permissions = "donate,contact,group,system";
      $sth->execute($card,$name,$permissions);
      $message = "Donor tables created";
      $action = "Home";
    } else {
      $message = "Donor tables not created. See koha-error.log";
    }
    $template->param('card',$card);
    $template->param('name',$name);
    #      
    # upload the account description from spreadsheet file
    #
  } elsif ($action eq 'Upload account descriptions') {
    $message = '';
    my $xlsxin = '';
    my $filename = scalar $cgi->param('excel');         # yes it can be any file
    if ($filename) {
      ($xlsxin,$message) = move_excel($filename,$cgi);
    } else {
      $message = "Account Description spreadsheet not specified";
    }
    $message = upload_accounts($self,$xlsxin,$trace) unless $message;
    $message = 'Account descriptions uploaded' unless $message;
    $sttrace->execute("Configure","Upload accounts",$message);
    
  } elsif ($action eq 'Home') {
    $message = '';
  }
  
  $template->param('message',$message);
  $template->param('ipath',$ipath);
  print $cgi->header();
  print $template->output();
}

sub upload_accounts {
  my ($self,$xlsxin,$trace) = @_;
  my ($colacct,$coldesc,$colded,$colincexp,$colmap,$colqb);
  my $cgi = $self->{cgi};
  my $book = ReadData($xlsxin);
  return "$xlsxin failed to open as a spreadsheet file" unless $book;
  my $sheets = $book->[0]->{sheets} || 1;
  while (!$book->[$sheets]->{maxcol}) {
    $sheets--;
    return "Can't find data in $xlsxin" unless $sheets;
  }
  my $sheet = $book->[$sheets];
  my $maxCol = $sheet->{maxCol};
  my $maxRow = $sheet->{maxrow};
  my $cells = $sheet->{cell};
  my $dbh = C4::Context->dbh;
  my $sttrace = $dbh->prepare("INSERT INTO bodatrace SET action=?,subaction=?,parm=?");
  $sttrace->execute("upload_accounts","opened","$xlsxin $maxRow x $maxCol");
  my $inact = $dbh->prepare("INSERT INTO bodaaccts SET donacct=?,acctdesc=?,deductible=?,incexp=?,map_to=?,qb=?");
  my ($donacct,$acctdesc,$deductible,$map_to,$incexp,$qb,$acctno);
  $colacct = column2number(scalar $cgi->param('colacct'));
  return "Column 'account' missing" unless defined($colacct);
  $coldesc   = column2number(scalar $cgi->param('coldesc'));
  $colded    = column2number(scalar $cgi->param('colded'));
  $colincexp = column2number(scalar $cgi->param('colincexp'));
  $colmap    = column2number(scalar $cgi->param('colmap'));
  $colqb     = column2number(scalar $cgi->param('colqb'));
  ($trace & 1024) && $sttrace->execute("Configure","Account columns",join(',',$colacct,$coldesc||'_',$colded||'_',
                                                                              $colincexp||'_',$colmap||'_',$colqb||'_',));
  $dbh->do("TRUNCATE bodaaccts");

  for (my $row = 2; $row <= $maxRow; $row++) {
    $donacct = $cells->[$colacct]->[$row];
    next unless $donacct;
    if (defined($coldesc)) {
      $acctdesc = $cells->[$coldesc]->[$row];
      $acctno = $donacct;
    } elsif ($donacct =~ m/\s*(\S+)\s+\S{0,2}\s*(\S.+)\s*$/) {
      $acctno = $1;
      $acctdesc = $2;
    } else {
      next;
    }
    $deductible = defined($colded)?$cells->[$colded]->[$row]:0;
    $incexp = defined($colincexp)?$cells->[$colincexp]->[$row]:0;
    $map_to = defined($colmap)?$cells->[$colmap]->[$row]:undef;
    $qb     = defined($colqb)?$cells->[$colqb]->[$row]:1;
    $inact->execute($acctno,$acctdesc,$deductible,$incexp,$map_to,$qb);
    ($trace & 1024) && $sttrace->execute("Configure","Account","'$donacct' is '$acctno' desc '$acctdesc'");
  }
  return "Accounts uploaded";
}

sub do_mysql_source {
  my ($self,$file,$trace) = @_;
  my $dbh = C4::Context->dbh;
  my $sttrace = $dbh->prepare("INSERT INTO bodatrace SET action=?,subaction=?,parm=?");
  open CRDB,"<",$file or warn "Can't open $file";
  while (my $cmd = <CRDB>) {
    $cmd =~ s/\;\*$//;
    $dbh->do($cmd);
  }
  $sttrace->execute("Configure","do source",$file);
}

#-------------------------------------
# *** Patron routines
#-------------------------------------
sub find_patron {
  my ($patron, $trace) = @_;
  my (%cards,%bcards);                                                    # return this
  # $cards{cardnumber} = {firstname=> ,surname=>, address=>, address2=>, city=>, state=>, zipcode=>, score=>}
  #if (($patron =~ m/Kurtz/i) || ($patron =~ m/Hadi/i)) {
  # $trace = 2;
  #}
  my $firstname = '';
  my $surname = '';
  my $suffix = '';

  my ($kcard,$kfirst,$ksur,$kaddress,$kaddress2,$kcity,$kstate,$kzip,$kscore,$korg,$sth);

  my $dbh = C4::Context->dbh;
  my $sttrace = $dbh->prepare("INSERT INTO bodatrace SET action=?,subaction=?,parm=?");
  #----------------------------------------
  # Try to find patron from name
  #----------------------------------------

  $korg = (substr($patron,0,1) eq '%');
  if ($korg) {
    $ksur = $patron.'%';
    $sth = $dbh->prepare("SELECT cardnumber, firstname, surname, ".
      "concat_ws(' ',streetnumber,address,streettype) address1, address2, city, state, zipcode ".
      "FROM borrowers WHERE surname like ? OR address like ? OR address2 like ?");
    $sth->execute($ksur,$ksur,$ksur);
  } else {
    ($firstname,$surname,$suffix) = split_name($patron);
    $ksur = $surname.'%';
    #  Look up surname
    $sth = $dbh->prepare("SELECT cardnumber, firstname, surname, ".
      "concat_ws(' ',streetnumber,address,streettype) address1, address2, city, state, zipcode ".
      "FROM borrowers WHERE surname like ?");
    $sth->execute($ksur);
  }
  ($trace & 2) && $sttrace->execute('get_name','searching',
                                    "$korg -> '$firstname' '$surname' '$ksur' '$suffix'");

  if ($sth->rows == 0) {
    ($trace & 2) && $sttrace->execute('get_name','returning',"No cards");
    return %cards;
  }

  # Found a bunch
  while (($kcard,$kfirst,$ksur,$kaddress,$kaddress2,$kcity,$kstate,$kzip) = $sth->fetchrow_array) {
    $kscore = '0';
    if (!$korg) {
      if ($firstname && $kfirst) {
        $kscore = name_eq($firstname,$surname,$kfirst,$ksur) || 0;
      } else {
        $kscore = name_eq("x",$surname,"x",$ksur) || 0;
      }
      ($trace & 2) && $sttrace->execute('get_name','got',"$kcard $kfirst $ksur  $kscore");
    }
    $bcards{$kcard} = {firstname=>$kfirst, surname=>$ksur, address=>$kaddress, score=>$kscore,
      address2=>$kaddress2, city=>$kcity, state=>$kstate, zipcode=>$kzip};
    if ($kscore >= 50) {
      $cards{$kcard} = $bcards{$kcard};
    }
  }
  %cards = %bcards unless %cards;
  my $cardDump = Dumper(%cards);
  ($trace & 2) && $sttrace->execute('get_name','returning',"cards: $cardDump");
  return %cards;
}

sub split_name {
  my $patron = shift;
  my ($firstname,$surname,$suffix);
  if (businessName($patron)) { return ('',$patron,'');}
  my %args = (
    allow_reversed => 1,
  );
  my $name = new Lingua::EN::NameParse(%args);
  my %name_comps;
  my $esqFlag = ($patron =~ s/\,?\s*Esq(uire)?\.?//);
  my $jrFlag = ($patron =~ s/\,?\s*Jr\.?//);

  my $error = $name->parse($patron);
  if ($error) {             # we gotta do it ourself
    my @splitNames = split /,\s*/,$patron;
    if (@splitNames == 2) {
      $patron = $splitNames[1].' '.$splitNames[0];
    }
    @splitNames = split /\s+/,$patron;
    $surname = pop @splitNames;
    $firstname = join(' ',@splitNames);
  } else {
    %name_comps = $name->components;
    $surname = $name_comps{surname_1};
    $suffix = $name_comps{suffix};
    $firstname = $name_comps{given_name_1};
    $firstname = "$firstname ".$name_comps{initials_1} if $name_comps{initials_1};
    $firstname = "$firstname ".$name_comps{middle_name} if $name_comps{middle_name};

  }
  if (!$surname) {
    $surname = $firstname;
    $firstname = '';
  }

  if (!$surname) {$surname = $patron;}
  $suffix = "Jr $suffix" if $jrFlag;
  $suffix = "$suffix Esq" if $esqFlag;
  return ($firstname,$surname,$suffix);
}
sub businessName {
  my ($sn) = @_;

  foreach my $flag (@businessFlag) {
    if ($sn =~ m/$flag/ ) { return 1;}
  }

  return 0;
}

#-------------------------------------
#  *** Miscellaneous routines
#-------------------------------------


sub move_excel {                        # This will now move any file
  my ($filename,$cgi) = @_;
  my ($message,$xlsxin);
  my $safe_filename_characters = "a-zA-Z0-9_.-";        # any suffix will do.
  my ($fname,$path,$ext) = fileparse($filename,'\..*$');
  $filename = $fname.$ext;
  $filename =~ tr/ /_/;
  if ( $filename =~ /^([$safe_filename_characters]+)$/ ) {
    $filename = $1;
    my $upload_fh = scalar $cgi->upload('excel');
    if (!defined $upload_fh) {
      $message = 'Upload file handle not defined';
    } else {
      my $io_fh = $upload_fh->handle;
      my $upload_dir = C4::Context->config('pluginsdir')."/Koha/Plugin/DonorApp/uploads";
      $xlsxin = "$upload_dir/$filename";
      if (!open(UPLOADFILE,">",$xlsxin)) {
        $message = "Can't open $xlsxin for output";
      } else {
        binmode UPLOADFILE;
        my ($buffer,$bytesread);
        my $uploadSize = 0;
        while ( $bytesread = $io_fh->read($buffer,1024) ){
          print UPLOADFILE $buffer;
          $uploadSize += $bytesread;
        }
        close UPLOADFILE;
        my $xlsxSize = -s $xlsxin;
        if (! $xlsxSize) {
          $message .= "$xlsxin is an empty file<br />";
        }
      }
    }
  } else {
    $message = "Filename $filename contains invalid characters";
  }
  return ($xlsxin,$message);
}

sub configured {
  my $recheck = $_[0];
  check_tables() if $recheck;
  return $new_tables;
}

sub get_businessFlag {
  @businessFlag = ();
  my $dbh = C4::Context->dbh;
  my $sth = $dbh->prepare("SELECT value FROM bodasystem WHERE name='business'");
  $sth->execute;
  while (my($flag) = $sth->fetchrow_array) {
    push @businessFlag,$flag;
  }
}

sub get_branchCodes {
  my $dbh = C4::Context->dbh;
  my $sth = $dbh->prepare("SELECT branchcode, branchname FROM branches");
  %Branches=();
  $sth->execute;
  while (my($branchcode,$branchname) = $sth->fetchrow_array) {
    $Branches{$branchcode} = $branchname;
  }
  $multibranch = (scalar(keys %Branches) > 1);
}

sub get_categoryCodes {
  my $dbh = C4::Context->dbh;
  my $sth = $dbh->prepare("SELECT categorycode,description FROM categories");
  %Categories = ();
  $sth->execute;
  while (my($categorycode,$description) = $sth->fetchrow_array) {
    $Categories{$categorycode} = $description;
  }
}
sub get_attributes {
  my $dbh = C4::Context->dbh;
  my $getAttributes = $dbh->prepare("SELECT name,value FROM bodasystem WHERE type='attribute'");
  $getAttributes->execute;
  while (my ($name,$value) = $getAttributes->fetchrow_array) {
    $Attributes{$name} = $value;
  }
}

sub check_tables {
  my $dbh = C4::Context->dbh;
  $new_tables = 0;
  my $sth = $dbh->table_info;
  while (my @row = $sth->fetchrow_array) {
    $new_tables = 1 if ($row[2] =~ m/^bodasystem/);
  }
}


sub ipath {
  return C4::Context->config('pluginsdir')."/Koha/Plugin/DonorApp/includes";
}

sub get_funds {
  my $dbh = shift;
  my $stfunds = $dbh->prepare("SELECT surname,cardnumber FROM borrowers WHERE categorycode='FUND'");
  $stfunds->execute;
  my $funds = $stfunds->fetchall_arrayref;
  my $fundnicks = $dbh->prepare("SELECT QBname, fundcard  from bodafunds WHERE fundcard not like 'bf%'");
  $fundnicks->execute;
  my $nicks = $fundnicks->fetchall_arrayref;
  push @$funds,@$nicks;
  my (%fundHash,$fundrow,$fundOut,$fund);
  foreach $fundrow (@$funds) {
    $fundHash{$fundrow->[0]} = $fundrow->[1];
  }
  foreach $fund (sort keys %fundHash) {
    push @$fundOut,[$fund,$fundHash{$fund}];
  }
  return $fundOut;
}

sub myref {
  my @v = @_;
  if (@v == 1) {
    if ($v[0] =~ m/HASH/i) {
      return ("HASH","HASH");
    } else {
      return ("SCALAR",$v[0]);
    }
  } else {
    return ("ARRAY","<".join(", ",@v).">");
  }
}

sub check_zip {
  my $z = shift;
  if (!$z) { return ''; }
  if ($z =~ m/^\s*\d\d\d\d(\-\d\d\d\d)?/) {
    return $z;
  }
  return '';
}


sub trim {
  my @out = @_;
  for (@out) {
    if ($_) {
      s/^\s+//;
      s/\s+$//;
    }
  }
  return @out == 1
  ? $out[0]
  : @out;
}

sub commify {
  return " " unless defined $_[0];
  my $number = shift;
  return " " unless $number =~ m/^\s*([\d\.]+)\s*$/;
  $number = $1;
  my $rev = sprintf("%8.2f",$number);
  $rev = reverse $rev;
  $rev =~ s/(\d\d\d)(?=\d)(?!\d*\.)/$1,/g;
  $rev = reverse $rev;
  return " $rev";
}

sub hashify {
  my $list = shift;
  my %hash;
  if ($list) {
    foreach (split(',',$list)){
      $hash{$_} = 1;
    }
  }
  return \%hash;
}

sub column2number {                     # 1 based column numbers
  my $column = shift;
  return undef if ! defined $column;
  #$column = trim $column;
  return undef if $column =~ m/^\s*$/;
  return undef if $column =~ m/-/;
  if (length($column) == 2) {
    return (ord(uc($column)) - ord('A') + 1) * 26 + (ord(uc(substr($column,1,1))) - ord('A')) + 1;
  }
  return ord(uc($column)) - ord('A') + 1;
}

sub number_the_columns {
  my @columnsByLetter = @_;
  # my $dbh = C4::Context->dbh;
  # my $sttrace = $dbh->prepare("INSERT INTO bodatrace SET action=?,subaction=?,parm=?");
  # $sttrace->execute('number columns','by letter',join(', ',@columnsByLetter));
  
  my (@columnsByNumber,$column);
  while (@columnsByLetter) {
    $column = column2number(shift @columnsByLetter);
    $column = '-' unless defined $column;
    push @columnsByNumber,$column;
  }
  # $sttrace->execute('number columns','by number',join(', ',@columnsByNumber));
  return @columnsByNumber;
}

sub number2column {
  my $column = shift;
  my $letters='ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  return '-' if !defined $column;
  $column = trim($column);
  return '-' if $column !~ m/\d+/;
  my $result = '';
  $column--;
  return substr($letters,$column,1) if ($column < 26);
  return substr($letters,int($column/26)-1,1).substr($letters,$column % 26,1);
}

  
sub fix_html {
  my $q = shift;
  if (!$q) { return '';}
    $q =~ s/\</\&lt\;/g;
    $q =~ s/\>/\&gt\;/g;
    $q =~ s/\'/\&quot\;/g;
    $q =~ s/\n/\<br \/\>/g;
    return $q;
}
sub unfix_html {
  my $q = shift;
  if (!$q) { return '';}
    $q =~ s/\<br \/\>/\n/g;
    $q =~ s/\&lt\;/\</g;
    $q =~ s/\&gt\;/\>/g;
    $q =~ s/\&quot\;/\'/g;
    return $q;
}


1;
