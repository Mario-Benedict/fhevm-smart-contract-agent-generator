import pandas as pd
import json
import os

df = pd.read_csv('final_labels.csv')

PATH_ARTIFACT  = '../output/contracts/'

# loop each row in df
for index, row in df.iterrows():
    file_name = row['file']

    CONTRACT_PATH = PATH_ARTIFACT + file_name
    # find the file only .json in the folder CONTRACT_PATH not .dbg.json and the .json file loaded bytecode not only 0x
    for file in os.listdir(CONTRACT_PATH):
        if file.endswith('.json') and not file.endswith('.dbg.json'):
            with open(os.path.join(CONTRACT_PATH, file)) as f:
                data = json.load(f)
                bytecode = data['bytecode']
                if bytecode != '0x':
                    bytecode = bytecode.replace('0x', '')
                    # split every 2 characters with space
                    bytecode = ' '.join([bytecode[i:i+2] for i in range(0, len(bytecode), 2)])
                    df.at[index, 'bytecode'] = bytecode
                    break

# swap the columns bytecode to after file column
cols = df.columns.tolist()
cols.insert(cols.index('file') + 1, cols.pop(cols.index('bytecode')))
df = df[cols]
# save the df to csv
df.to_csv('final_labels_with_bytecode.csv', index=False)