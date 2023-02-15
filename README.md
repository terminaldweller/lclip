# lclip
a minimal clip manager in lua.</br>
This is technically just the back-end. I'm using dmenu as the front-end but it has its limitations.</br>
```sh
sqlite3 $(cat /tmp/lclipd_db_name) 'select content from lclipd;' | dmenu
```

## TODO
* The DB permissions are not being taken care of.</br>
* This doesn't support wayland yet.</br>
