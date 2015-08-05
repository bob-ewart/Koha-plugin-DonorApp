<br />

[% IF message %]
<h4 class='alert-info'>[% message %]</h4>
[% END %]

[% IF dump %]
  <pre>Dump [% dump %]</pre>
[% END %]

[% MACRO form BLOCK %]
  <form method="get">
  <input type='hidden' name='class' value="[% CLASS %]" />
  <input type='hidden' name='method' value="[% METHOD %]" />
[% END %]

<!--  [% template.name %] +++ -->
