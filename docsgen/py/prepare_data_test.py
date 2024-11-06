import os

from prepare_data import prepare_json_data

data = os.path.abspath("./testdata")
outfile = os.path.abspath("./tmp/testcomments.json")


prepare_json_data(data, outfile)
