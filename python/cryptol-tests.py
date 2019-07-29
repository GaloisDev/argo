import os
from pathlib import Path

from cryptol import CryptolConnection, CryptolContext, cry

dir_path = Path(os.path.dirname(os.path.realpath(__file__)))

cryptol_path = dir_path.parent.joinpath('test-data')

c = CryptolConnection(
    "cabal v2-exec cryptol-remote-api -- --dynamic4",
    cryptol_path=cryptol_path
)

# Regression tests on nested sequences

id_1 = c.send_message("load module", {"module name": "M", "state": []})
reply_1 = c.wait_for_reply_to(id_1)
assert('result' in reply_1)
assert('state' in reply_1['result'])
assert('answer' in reply_1['result'])
state_1 = reply_1['result']['state']

id_2 = c.send_message("evaluate expression", {"expression": {"expression":"call","function":"f","arguments":[{"expression":"bits","encoding":"hex","data":"ff","width":8}]}, "state": state_1})
reply_2 = c.wait_for_reply_to(id_2)
assert('result' in reply_2)
assert('answer' in reply_2['result'])
assert('value' in reply_2['result']['answer'])
assert(reply_2['result']['answer']['value'] ==
       {'data': [{'data': 'ff', 'width': 8, 'expression': 'bits', 'encoding': 'hex'},
                 {'data': 'ff', 'width': 8, 'expression': 'bits', 'encoding': 'hex'}],
        'expression': 'sequence'})

id_3 = c.send_message("evaluate expression", {"expression": {"expression":"call","function":"g","arguments":[{"expression":"bits","encoding":"hex","data":"ff","width":8}]}, "state": state_1})
reply_3 = c.wait_for_reply_to(id_3)
assert('result' in reply_3)
assert('answer' in reply_3['result'])
assert('value' in reply_3['result']['answer'])
assert(reply_3['result']['answer']['value'] ==
       {'data': [{'data': 'ff', 'width': 8, 'expression': 'bits', 'encoding': 'hex'},
                 {'data': 'ff', 'width': 8, 'expression': 'bits', 'encoding': 'hex'}],
        'expression': 'sequence'})

id_4 = c.send_message("evaluate expression", {"expression":{"expression":"call","function":"h","arguments":[{"expression":"sequence","data":[{"expression":"bits","encoding":"hex","data":"ff","width":8},{"expression":"bits","encoding":"hex","data":"ff","width":8}]}]}, "state": state_1})
reply_4 = c.wait_for_reply_to(id_4)
assert('result' in reply_4)
assert('answer' in reply_4['result'])
assert('value' in reply_4['result']['answer'])
assert(reply_4['result']['answer']['value'] ==
       {'data': [{'data': 'ff', 'width': 8, 'expression': 'bits', 'encoding': 'hex'},
                 {'data': 'ff', 'width': 8, 'expression': 'bits', 'encoding': 'hex'}],
        'expression': 'sequence'})
