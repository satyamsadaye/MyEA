#!/bin/bash
DIR='/home/satyam/Desktop/MetaTrader Common Files'
for f in "$DIR"/Partial_prop_Node*.csv; do
    [ -f "$f" ] && rm "$f" && echo "Deleted: $f"
done
echo "Done."
