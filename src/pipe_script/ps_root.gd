extends Node

func read_file(path):
	var file = File.new()
	file.open(path, File.READ)
	var content = file.get_as_text()
	file.close()
	return content

var token_types = {
	"!": "call",
	"%(": "print_call",
	"==": "cmp_eq",
	">=": "cmp_gte",
	"<=": "cmp_lte",
	">": "cmp_gt",
	")": "bracket_right",
	"(": "bracket_left",
	"<": "cmp_lt",
	"=": "assign",
	"*": "math_mul",
	"/": "math_div",
	"+": "math_add",
	"-": "math_div",
	",": "seperator",
	":": "atom",
	"\"": "string",
	"#": "comment",
}

# a handy function to check if a string of bytes is alphanumeric
func is_alphanumeric(s: String):
	for byte in s.to_ascii():
		if !((byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)):
			return false
	return true

func parse(body: String):
	var body_length = body.length()
	var tokens = []
	
	var is_comment = false
	var is_atom = false
	var is_string = false
	var cross_token = ""
	
	# iterate through the entire body
	var char_idx = 0
	while char_idx < body_length:
		var should_do_token_check = !(is_comment || is_atom || is_string)
		
		# if we're a comment / atom / string make sure to chain words together
		if is_comment:
			var chr = body[char_idx]
			if chr != "\n":
				cross_token += chr
			else:
				if cross_token != "":
					tokens.back().body += cross_token
					cross_token = ""
				is_comment = false
		elif is_atom:
			var chr = body[char_idx]
			if is_alphanumeric(chr):
				cross_token += chr
			else:
				if cross_token != "":
					tokens.back().body += cross_token
					cross_token = ""
				is_atom = false
		elif is_string:
			var chr_2 = body[char_idx - 2] if char_idx >= 2 else ""
			var chr_1 = body[char_idx - 1] if char_idx >= 1 else ""
			var chr_0 = body[char_idx]
			if chr_0 == "\"" && chr_1 != "\\" && chr_2 != "\\":
				if cross_token != "":
					tokens.back().body += cross_token
					cross_token = ""
				is_string = false
			else:
				cross_token += chr_0
		
		# check each token, see if we match
		var token
		if should_do_token_check:
			for token_type in token_types.keys():
				var substr = body.substr(char_idx, token_type.length())
				if substr == token_type:
					token = {
						body = substr,
						type = token_types[token_type]
					}
					break
		
		if token:
			if token.type == "comment":
				is_comment = true
			elif token.type == "atom":
				is_atom = true
			elif token.type == "string":
				is_string = true
			
			tokens.append(token)
			char_idx += token.body.length()
		else:
			char_idx += 1
	
	for current_token in tokens:
		print(current_token)

func _ready():
	var demo: String = read_file("res://src/pipe_script/demo.psl")
	
	parse(demo)
	
