# Koha-plugin-DonorApp
This is a plugin for the Koha ILS which tracks donors.  It includes importing income from
accounting programs, individual donor profiles and comprehensive report generation.

Installation:

Turn on plugins in Koha in koha-conf.xml and in Global system preferences -- Enhanced contents

Install gcc

Install the following from your distribution  or from CPAN.

Spreadsheet::Read *
Spreadsheet::ReadSXC
DateTime::Format::Excel
Excel::Writer::XLSX *
Lingua::EN::NameParse *
Lingua::EN::Nickname
Text::Mataphone
String::Approx *
Lingua::EN::MatchNames
String::Similarity *
Data::Dumper::Concise *
(* can be installed from Debian 7)

In Tools -> Tool plugins select the donorapp.kpz file and upload it

There are a number of parameters which will need to be configured for your system.  See the 
installation section of the donorapp.odt file in the Testing subdirectory.


