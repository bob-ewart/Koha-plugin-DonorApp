<table class='none'>
  <tr><th>Name</th><td>[% patron.firstname %] [% patron.surname %]</td></tr>
  <tr><th>Address</th><td>
        [% IF patron.address %][% patron.address %] <br />[% END %]
        [% IF patron.address2 %][% patron.address2 %] <br />[% END %]
        [% IF patron.city %][% patron.city %] | [% patron.state %] | [% patron.zipcode %][% END %]
        </td></tr>
  <tr><th>Phone</th><td>[% IF patron.phone %]Home: [% patron.phone %][% END %]
                        [% IF patron.mobile %] Cell:[% patron.mobile %][% END %]</td></tr>
  <tr><th>Email</th><td>[% patron.email %]</td></tr>
  [% IF patron.B_address %]<tr><td>&nbsp;</td></tr>
    <tr><th colspan='2'>Alternate Address</th></tr>
    <tr><th>Address</th><td>[% patron.B_address %] <br />
          [% IF patron.B_address2 %][% patron.B_address2 %] <br /> [% END %]
          [% patron.B_city %] | [% patron.B_state %] | [% patron.B_zipcode %]</td></tr>
    <tr><th>Phone</th><td>[% patron.B_phone %]</td></tr>
    <tr><th>Email</th><td>[% patron.B_email %]</td></tr>
    <tr><th colspan='2'>
    [% form %]
      <input type='hidden' name='card' value='[% card %]' />
      <input type='submit' name='action' value='Swap' /> Addresses
      </form>
      </th>
    </tr>
    <tr><td>&nbsp;</td></tr>
  [% END %]
  [% IF patron.borrowernotes %]
    <tr><th>Note</th><td>[% patron.borrowernotes %]</td></tr>
  [% END %]
  <tr><th>Category</th><td>[% patron.categorycode %]</td><tr>
  [% IF patron.branchcode %]
    <tr><th>Branch</th><td>[% patron.branchcode %]</td></tr>
  [% END %]
  <tr><th>Card</th><td>[% card %] 
    Joined: [% patron.dateenrolled %]
    Expires: [% patron.dateexpiry %]</td><tr>
  <tr><th>Select codes</th><td>
      [% IF patron.mail %]Mail:[% patron.mail %][% END %]
      [% IF patron.publish %] Publish:[% patron.publish %][% END %]
      [% IF patron.selectcodes %] --[% patron.selectcodes %][% END %]
      </td></tr>
  [% IF patron.family %]
  <tr><th>Family:</th><td>
    [% form %]
    <input type='hidden' name='action' value='Show' />
    [% patron.family %] </td></tr>
    </form>
  [% END %]
</table><br />
[% IF borrower %]
  <a href='/cgi-bin/koha/members/moremember.pl?borrowernumber=[% patron.borrowernumber %]' target='_blank'>Edit Koha record </a>
[% END %]
<br />