  [% form %]
  <br />
      <h3>Select Patron by</h3>
        Card Number: <input type="text" name="card"  size='6' />&emsp;
        or Name: <input type='text' name='patron' size='30'  />
        <br/>
    <input name="action" type="submit" value="[% action %]" />
    <input name="subaction" type="hidden" value="[% subaction %]" />
  </form>

