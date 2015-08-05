[% form %]
  <input type='hidden' name='action' value='Reports' />
  <select name='repid' >
    [% FOREACH row IN reports %]
      <option value="[% row.0 %]">([% row.0 %]) [% row.1 %]</option>
    [% END %]
  </select>
  <input type='submit' name='subaction' value='Run' />
  [% IF permissions.group %]
    <input type='submit' name='subaction' value='Edit' />
    <input type='submit' name='subaction' value='New' />
    <input type='submit' name='subaction' value='Delete' />
  [% END %]
</form>
