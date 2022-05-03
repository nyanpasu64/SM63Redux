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
	"==": "math_eq",
	"~=": "math_neq",
	">=": "math_gte",
	"<=": "math_lte",
	"&&": "math_and",
	"||": "math_or",
	">": "math_gt",
	"<": "math_lt",
	")": "bracket_right",
	"(": "bracket_left",
	"=": "assign",
	"*": "math_mul",
	"/": "math_div",
	"+": "math_add",
	"-": "math_sub",
	",": "seperator",
	":": "atom",
	"\"": "string",
	"#": "comment",
	"\t": "tab",
}

var math_order = {
	"math_mul": 5,
	"math_div": 5,
	"math_add": 4,
	"math_sub": 4,
	"math_eq": 3,
	"math_neq": 3,
	"math_gte": 3,
	"math_lte": 3,
	"math_gt": 3,
	"math_lt": 3,
	"math_and": 2,
	"math_or": 1,
}

var expression_acceptance_table = {
	"bracket_left": {
		"bracket_left": true,
		"bracket_right": true,
		"number": true,
		"call": true,
		"raw": true,
		"math_": false,
	},
	"bracket_right": {
		"bracket_left": true,
		"bracket_right": true,
		"number": false,
		"call": false,
		"raw": false,
		"math_": true,
	},
	"number": {
		"bracket_left": false,
		"bracket_right": true,
		"number": false,
		"call": false,
		"raw": false,
		"math_": true,
	},
	"call": {
		"bracket_left": false,
		"bracket_right": true,
		"number": false,
		"call": false,
		"raw": false,
		"math_": true,
	},
	"raw": {
		"bracket_left": false,
		"bracket_right": true,
		"number": false,
		"call": false,
		"raw": false,
		"math_": true,
	},
	"math_": {
		"bracket_left": true,
		"bracket_right": false,
		"number": true,
		"call": true,
		"raw": true,
		"math_": false,
	},
	"begin": {
		"bracket_left": true,
		"bracket_right": false,
		"number": true,
		"call": true,
		"raw": true,
		"math_": false,
	},
}

# a handy function to check if a string of bytes is alphanumeric
func is_alphanumeric(s: String):
	for byte in s.to_ascii():
		if !((byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 46):
			return false
	return true

func parse(body: String):
	var tokens = parse_tokens(body)
	interpret(tokens)

func is_literal(token):
	return token.type == "string" || token.type == "atom" || token.type == "number"

func is_value(token):
	return is_literal(token) || token.type == "call" || token.type == "raw"

func handle_expression(queue: Array):
	var idx = 0
	var size = queue.size()
	# first handle all brackets
	while idx < size:
		var item = queue[idx]
		if typeof(item) == TYPE_ARRAY:
			# if there were brackets, interpret that first
			# we convert back to a string to be consistent
			queue[idx] = handle_expression(queue[idx])
		idx += 1
	
	# handle the math operations
	while size > 1:
		# find the best index to start the calculation from, multiplication goes before addition
		var best = {
			idx = 0,
			order = 0,
		}
		for best_idx in size:
			var type = queue[best_idx].type
			if type.begins_with("math_"):
				var order = math_order[type]
				if order > best.order:
					best.idx = best_idx + 1
					best.order = order
		
		# get the operand and the two numbers to use
		var op = queue[best.idx - 1].type
		var a = float(queue[best.idx - 2].body) if queue[best.idx - 2].type == "number" else 0 #TODO: get variable
		var b = float(queue[best.idx].body) if queue[best.idx].type == "number" else 0 #TODO: get variable
		
		var result = 0
		match op:
			"math_add":
				result = a + b
			"math_sub":
				result = a - b
			"math_div":
				result = a / b
			"math_mul":
				result = a * b
			"math_eq":
				result = 1 if a == b else 0
			"math_neq":
				result = 0 if a == b else 1
			"math_gte":
				result = 1 if a >= b else 0
			"math_lte":
				result = 1 if a <= b else 0
			"math_gt":
				result = 1 if a > b else 0
			"math_lt":
				result = 1 if a < b else 0
			"math_and":
				result = 1 if a != 0 && b != 0 else 0
			"math_or":
				result = 1 if a != 0 || b != 0 else 0
		
		# handle the stack
		queue[best.idx] = {
			body = str(result),
			type = "number",
			line = queue[best.idx].line
		}
		queue.pop_at(best.idx - 2)
		queue.pop_at(best.idx - 2)
		size = queue.size()
	return queue[0]

func get_expression_sequence(tokens, token_size, token_idx):	
	var sequence = []
	var prev_type = "begin"
	while token_idx < token_size:
		var current_type = tokens[token_idx].type
		current_type = "math_" if current_type.begins_with("math_") else current_type
		prev_type = "math_" if prev_type.begins_with("math_") else prev_type
		
		if !expression_acceptance_table.has(prev_type):
			break
		if !expression_acceptance_table[prev_type].has(current_type):
			break
		if expression_acceptance_table[prev_type][current_type]:
			sequence.append(tokens[token_idx])
		else:
			break
		
		prev_type = current_type
		token_idx += 1
	
	# if we actually detected an expression, make sure to handle the brackets properly
	var return_seq = sequence
	if sequence.size() > 2:
		var seq_idx = 0
		var stack = []
		var queue = []
		while seq_idx < sequence.size():
			var token = sequence[seq_idx]
			if token.type == "bracket_left":
				token = null
				stack.append(queue)
				queue = []
			elif token.type == "bracket_right":
				token = queue
				queue = stack.pop_back()
			
			if token:
				queue.append(token)
			seq_idx += 1
		return_seq = queue
	
	# return
	return [return_seq, sequence.size()]

func interpret(tokens):
	var token_size = tokens.size()
	var variables = {}
	
	var token_idx = 0
	while token_idx < token_size:
		var token = tokens[token_idx]
		var prev_token = tokens[token_idx - 1] if token_idx > 0 else null
		var dprev_token = tokens[token_idx - 2] if token_idx > 1 else null
		var idx_inc = 1
		
		var possible_value = token
		var expr_seq = get_expression_sequence(tokens, token_size, token_idx)
		if expr_seq[1] > 2:
			idx_inc = expr_seq[1]
			possible_value = handle_expression(expr_seq[0])
		
		if prev_token && dprev_token && dprev_token.type == "raw" && prev_token.type == "assign":
			variables[dprev_token.body] = possible_value
		
		token_idx += idx_inc
	print(variables)

func parse_tokens(body: String):
	var body_length = body.length()
	var tokens = []
	
	var is_comment = false
	var is_atom = false
	var is_string = false
	var cross_token = ""
	var line_nr = 0
	
	# iterate through the entire body
	var char_idx = 0
	while char_idx < body_length:
		var should_do_token_check = !(is_comment || is_atom || is_string)
		
		if body[char_idx] == "\n":
			line_nr += 1
		
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
						type = token_types[token_type],
						line = line_nr
					}
					break
		
		# add 'raw' tokens, these are literals or variable names
		if should_do_token_check:
			var chr = body[char_idx]
			if is_alphanumeric(chr) && token == null:
				cross_token += chr
			elif cross_token != "":
				tokens.append({
					body = cross_token,
					type = "number" if cross_token.is_valid_float() else "raw",
					line = line_nr
				})
				cross_token = ""
		
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
	
	# filter comment tokens
	var returns = []
	var make_next_call = false
	for token_idx in tokens.size():
		if tokens[token_idx].type != "comment":
			if tokens[token_idx].type == "call":
				make_next_call = true
			else:
				if make_next_call:
					if tokens[token_idx].type != "raw":
						printerr("COMPILE ERROR:\nLine %d: Can only call function names." % tokens[token_idx].line)
					tokens[token_idx].type = "call"
				returns.append(tokens[token_idx])
	
	return returns

func _ready():
	var demo: String = read_file("res://src/pipe_script/demo.psl")
	
	parse(demo)
	
