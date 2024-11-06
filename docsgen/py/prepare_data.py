import os
import re
import json

# data_dir = "train/"
# output_file = "comments.json"

# Pattern to match [INS], [INPUT], and [RESPONSE] blocks
pattern = (
    r"\[INS\](.*?)\[/INS\]\s*"
    r"((?:\[INPUT\](.*?)\[/INPUT\]\s*\[RESPONSE\](.*?)\[/RESPONSE\]\s*)+)"
)


def prepare_json_data(data_dir, output_file):
    documents = []

    for filename in os.listdir(data_dir):
        # Only process .txt files (or adjust as needed)
        if filename.endswith(".txt"):
            file_path = os.path.join(data_dir, filename)

            with open(file_path, "r") as f:
                content = f.read()

            matches = re.findall(pattern, content, re.DOTALL)

            for match in matches:
                instruction = match[0].strip()
                # Split the matched input-response pairs
                input_response_pairs = re.findall(
                    r"\[INPUT\](.*?)\[/INPUT\]\s*\[RESPONSE\](.*?)\[/RESPONSE\]",
                    match[1],
                    re.DOTALL,
                )

                for input_code, response in input_response_pairs:
                    documents.append(
                        {
                            "instruction": instruction,
                            "input": input_code.strip(),
                            "output": response.strip(),
                        }
                    )

    with open(output_file, "w") as f:
        json.dump(documents, f, indent=4)

    return True
