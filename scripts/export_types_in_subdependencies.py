import glob
import re

require_pattern = re.compile(r'return (require.+?"(.+?)"\]\["(.+?)\")(.*)')

cache = {}

for path in glob.glob("DevPackages/_Index/*/*.lua"):
	with open(path, "r") as file:
		contents = file.read()
		require_match = require_pattern.search(contents)
		if require_match is None:
			continue
	
	folder1 = require_match.group(2)
	folder2 = require_match.group(3)

	if folder1 == "evaera_promise@4.0.0":
		continue

	new_contents = cache.get((folder1, folder2))
	if new_contents is None:
		middle = f"_Index/{folder1}/{folder2}/src/init."
		found_paths = glob.glob(f"Packages/{middle}lua") + glob.glob(f"Packages/{middle}luau") + glob.glob(f"DevPackages/{middle}lua") + glob.glob(f"DevPackages/{middle}luau")
		
		if len(found_paths) == 0:
			print(f"Could not find {folder1}/{folder2} init file from {path}")
			middle = f"_Index/{folder1}/{folder2}/lib/init."
			found_paths = glob.glob(f"Packages/{middle}lua") + glob.glob(f"Packages/{middle}luau") + glob.glob(f"DevPackages/{middle}lua") + glob.glob(f"DevPackages/{middle}luau")
			
			if len(found_paths) == 0:
				print(f"Could not find {folder1}/{folder2} init file from {path} with {middle}")
				continue
		
		found_path = found_paths[0]

		new_lines = [f"local MODULE = {require_match.group(1)}{require_match.group(4)}"]

		with open(found_path, "r", encoding = "utf-8") as file:
			dependency_contents = file.read()
			
			for line in dependency_contents.splitlines():
				export_type_search = re.search(r"^export type (.+?)\b(<(.+?)>)?", line)
				if export_type_search is None:
					continue

				export_type = export_type_search.group(1)

				# Doesn't work with `T<X = U<V>>`
				generics = export_type_search.group(3)
				if generics is None:
					new_lines.append(f"export type {export_type} = MODULE.{export_type}")
					continue

				building_name = ""
				read_type_name = True
				type_names = []

				for character in generics:
					if read_type_name and character.isalpha():
						building_name += character
					else:
						if len(building_name) > 0:
							type_names.append(building_name)
							building_name = ""
							read_type_name = character == ','

				if len(building_name) > 0:
					type_names.append(building_name)
				
				generics = generics.replace(" = JestMatcherState", " = any").replace(" = Object", " = {}")

				new_lines.append(f"export type {export_type}<{generics}> = MODULE.{export_type}<{', '.join(type_names)}>")

		new_lines.append("return MODULE")
		
		new_contents = "\n".join(new_lines)
		cache[(folder1, folder2)] = new_contents

	with open(path, "w") as file:
		file.write(new_contents)
