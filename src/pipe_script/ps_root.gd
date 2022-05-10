extends Node

func read_file(path):
	var file = File.new()
	file.open(path, File.READ)
	var content = file.get_as_text()
	file.close()
	return content

var token_types = {
	"?": "call",
	"%(": "print_call",
	"==": "math_eq",
	"!=": "math_neq",
	">=": "math_gte",
	"<=": "math_lte",
	"&&": "math_and",
	"||": "math_or",
	"!": "logic_not",
	"@": "anon_func",
	">": "math_gt",
	"<": "math_lt",
	")": "bracket_right",
	"(": "bracket_left",
	"{": "func_left",
	"}": "func_right",
	"=": "assign",
	"*": "math_mul",
	"/": "math_div",
	"+": "math_add",
	"-": "math_sub",
	",": "seperator",
	":": "atom",
	"\"": "string",
	"#": "comment",
}

var math_order = {
	"logic_not": 5,
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
		"logic_not": true,
	},
	"bracket_right": {
		"bracket_left": true,
		"bracket_right": true,
		"number": false,
		"call": false,
		"raw": false,
		"math_": true,
		"logic_not": true,
	},
	"number": {
		"bracket_left": false,
		"bracket_right": true,
		"number": false,
		"call": false,
		"raw": false,
		"math_": true,
		"logic_not": true,
	},
	"call": {
		"bracket_left": true,
		"bracket_right": false,
		"number": false,
		"call": false,
		"raw": false,
		"math_": true,
		"logic_not": true,
	},
	"raw": {
		"bracket_left": false,
		"bracket_right": true,
		"number": false,
		"call": false,
		"raw": false,
		"math_": true,
		"logic_not": false,
	},
	"math_": {
		"bracket_left": true,
		"bracket_right": false,
		"number": true,
		"call": true,
		"raw": true,
		"math_": false,
		"logic_not": true,
	},
	"logic_not": {
		"bracket_left": true,
		"bracket_right": false,
		"number": true,
		"call": true,
		"raw": true,
		"math_": false,
		"logic_not": false,
	},
	"begin": {
		"bracket_left": true,
		"bracket_right": false,
		"number": true,
		"call": true,
		"raw": true,
		"math_": false,
		"logic_not": true,
	},
}

# a handy function to check if a string of bytes is alphanumeric
func is_alphanumeric(s: String):
	for byte in s.to_ascii():
		if !((byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 46):
			return false
	return true

func parse(body: String):
	body += "\n"
	var tokens = parse_tokens(body)
	var scope = chunkify_tokens(tokens)
	interpret(scope)

# use for debugging
func print_scope(scope, prefix = ""):
	var idx = 0
	for token in scope.tokens:
		if token.type == "scope":
			print(prefix, idx, "> function body of %s: " % token.func_id)
			print_scope(token, prefix + "\t")
		else:
			print(prefix, idx, "> ", token)
		idx += 1

# put tokens from functions into chunks, so it's easier for the interpreter to read
func chunkify_tokens(tokens):
	var token_idx = 0
	var token_size = tokens.size()
	var stack = []
	var scope = {
		body = "",
		type = "scope",
		func_id = ".?",
		params = [],
		guard_expr = [],
		variables = {},
		funcs = [],
		tokens = []
	}
	while token_idx < token_size:
		var token = tokens[token_idx]
		if token.type == "func_left":
			token = null
			# get the function name
			var func_name_idx = token_idx - 1
			var func_name = ""
			while func_name_idx >= 0:
				var func_token = tokens[func_name_idx]
				var bracket_token = tokens[func_name_idx + 1]
				if (func_token.type == "raw" || func_token.type == "anon_func") && bracket_token.type == "bracket_left":
					func_name = func_token.body if func_token.type == "raw" else ".anon@%d" % token_idx
					break
				func_name_idx -= 1
			# if we ran out of indexes, that means something went wrong
			if func_name_idx == -1:
				printerr("COMPILE ERROR:\nLine %d: Incomplete function definition." % tokens[token_idx].line)
				break
			# get the parameters
			var params_data = get_param_sequence(tokens, token_size, func_name_idx + 1)
			var guard_idx = params_data[1] + func_name_idx + 2
			var guard = get_expression_sequence(tokens, token_size, guard_idx)
			
			# remove the old data
			for _idx in token_idx - func_name_idx:
				scope.tokens.pop_back()
			
			stack.append(scope)
			scope = {
				body = "",
				type = "scope",
				func_id = func_name,
				params = params_data[2],
				guard_expr = guard[0],
				variables = {},
				funcs = [],
				tokens = []
			}
		elif token.type == "func_right":
			token = scope
			scope = stack.pop_back()
		
		if token:
			scope.tokens.append(token)
		
		token_idx += 1
	return scope

func is_literal(token):
	return token.type == "string" || token.type == "atom" || token.type == "number"

func is_value(token):
	return is_literal(token) || token.type == "call" || token.type == "raw" || token.type == "scope"

func handle_expression(scope, expr, extra_variables = []):
	var idx = 0
	var size = expr.size()
	# first handle all brackets
	while idx < size:
		var item = expr[idx]
		if typeof(item) == TYPE_ARRAY:
			# if there were brackets, interpret that first
			# we convert back to a string to be consistent
			expr[idx] = handle_expression(scope, expr[idx], extra_variables)
		else:
			if item.type == "raw":
				item.body = scope.variables[item.body].body if scope.variables.has(item.body) else extra_variables[item.body].body
				item.type = "number"
			elif item.type == "call":
				#TOMORROW: make this work
				pass
		idx += 1
	
	# handle the math operations
	while size > 1:
		# find the best index to start the calculation from, multiplication goes before addition
		var best = {
			idx = 0,
			order = 0,
		}
		for best_idx in size:
			var type = expr[best_idx].type
			if type.begins_with("math_") || type.begins_with("logic_"):
				var order = math_order[type]
				if order > best.order:
					best.idx = best_idx + 1
					best.order = order
		
		# get the opcode and the two operands to use
		var op = expr[best.idx - 1].type
		var b = float(expr[best.idx].body) if expr[best.idx].type == "number" else 0 #TODO: get variable
		var result = 0
		if op == "logic_not":
			result = 0 if b else 1
		else:
			var a = float(expr[best.idx - 2].body) if expr[best.idx - 2].type == "number" else 0 #TODO: get variable
			
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
					result = 0 if a < b else 1
				"math_lte":
					result = 0 if a > b else 1
				"math_gt":
					result = 1 if a > b else 0
				"math_lt":
					result = 1 if a < b else 0
				"math_and":
					result = a & b
				"math_or":
					result = a | b
			
		# handle the stack
		expr[best.idx] = {
			body = str(result),
			type = "number",
			line = expr[best.idx].line
		}
		if op == "logic_not":
			expr.pop_at(best.idx - 1)
		else:
			expr.pop_at(best.idx - 2)
			expr.pop_at(best.idx - 2)
		size = expr.size()
	return expr[0]

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

# get a sequence of parameters, this will only work when called on a valid sequence
# it returns the sequence of tokens, the actual size it read and the actual parameter names
func get_param_sequence(tokens, token_size, token_idx):
	var sequence = []
	var params = []
	var actual_size = 0
	while token_idx < token_size:
		var token = tokens[token_idx]
		if token.type == "bracket_left":
			pass
		elif token.type == "bracket_right":
			break
		elif token.type == "raw" || token.type == "seperator":
			sequence.append(token)
			if token.type == "raw":
				params.append(token.body)
		actual_size += 1
		token_idx += 1
	return [sequence, actual_size, params]

func call_builtin(token):
	pass

func get_argument_sequence(tokens, token_size, token_idx):
	var args = []
	var actual_size = 0
	while token_idx < token_size:
		var token = tokens[token_idx]
		var idx_inc = 1
		if token.type == "bracket_left":
			pass
		elif token.type == "bracket_right":
			break
		else:
			var expr = get_expression_sequence(tokens, token_size, token_idx)
			if expr[0].size() > 1:
				args.append(expr[0])
				idx_inc = expr[1]
			elif is_value(token):
				args.append(token)
		token_idx += idx_inc
		actual_size += idx_inc
	return [args, actual_size]

# Interprets the tokens & executes them
func interpret(scope):
	print("\n")
	print_scope(scope)
	print("\n")
	var root_scope = scope # just in case
	var scope_stack = []
	var expression_go_back = [-1, -1, []] # idx, end_idx, expression
	
	var token_idx = 0
	var token_size = scope.tokens.size()
	while token_idx < token_size:
		var token = scope.tokens[token_idx]
		var prev_token = scope.tokens[token_idx - 1] if token_idx > 0 else null
		var dprev_token = scope.tokens[token_idx - 2] if token_idx > 1 else null
		var idx_inc = 1
		
		print("EXEC: ", token_idx, " : ", token.body)
		
		var possible_value = token
		if expression_go_back[0] == -1:
			var expr_seq = get_expression_sequence(scope.tokens, token_size, token_idx)
			if expr_seq[0].size() > 1:
				expression_go_back = [token_idx, token_idx + expr_seq[1] - 1, expr_seq]
		elif token_idx == expression_go_back[0]:
			idx_inc = expression_go_back[2][1]
			possible_value = handle_expression(scope, expression_go_back[2][0])
			expression_go_back = [-1, -1, []]
		elif token_idx == expression_go_back[1]:
			idx_inc -= expression_go_back[2][1]
		
		if token.type == "call":
			var args = get_argument_sequence(scope.tokens, token_size, token_idx + 1)
			idx_inc = args[1]
			
			# find the function to switch too
			var target_scope
			for new_scope in scope.funcs:
				if new_scope.func_id == token.body && new_scope.params.size() == args[0].size():
					#TODO: do the guard check
#					handle_expression(scope, new_scope.guard_expr)
					target_scope = new_scope
					#handle_expression(new_scope.guard_expr)
					break
			if target_scope == null:
				printerr("ERROR:\nLine %d: Attempt to call undefined function.")
			
			# switch to the new scope
			scope_stack.append([scope, token_idx + idx_inc])
			scope = target_scope
			token_size = scope.tokens.size()
			token_idx = 0
			idx_inc = 0
		
		if prev_token && dprev_token && dprev_token.type == "raw" && prev_token.type == "assign":
			if possible_value.type == "scope":
				# we don't assign functions to variables,
				# we simply change the func_id
				possible_value.func_id = dprev_token.body
				scope.funcs.append(possible_value)
			else:
				scope.variables[dprev_token.body] = possible_value
#			print(dprev_token.body, " = ", possible_value)
		elif token.type == "scope":
			scope.funcs.append(token)
#			print(dprev_token.body, " = ", possible_value)
		
		# increment the token index
		token_idx += idx_inc
		
		# if we ran out of instructions, go back a stack
		if token_idx >= token_size && scope_stack.size() > 0:
			print(possible_value) #this would be the return value
			var prev = scope_stack.pop_back()
			scope = prev[0]
			token_idx = prev[1]
			token_size = scope.tokens.size()
		
#		global_idx += idx_inc
	
	print("\nAppData:")
	for key in scope.variables.keys():
		print(key, " = ", scope.variables[key])
	for f in scope.funcs:
		print("function %s" % f.func_id)

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
	var middle = []
	var make_next_call = false
	for token_idx in tokens.size():
		if tokens[token_idx].type != "comment":
			if tokens[token_idx].type == "call":
				make_next_call = true
			else:
				# merge the call type into a singular token
				if make_next_call:
					if tokens[token_idx].type != "raw":
						print(tokens)
						printerr("COMPILE ERROR:\nLine %d: Can only call function names." % tokens[token_idx].line)
					tokens[token_idx].type = "call"
					make_next_call = false
				# convert atoms into strings
				if tokens[token_idx].type == "atom":
					tokens[token_idx].body = tokens[token_idx].body.substr(1)
					tokens[token_idx].type = "string"
				middle.append(tokens[token_idx])
	
	return middle
#	var returns = []
#	var token_size = middle.size()
#	var token_idx = 0
#	while token_idx < token_size:
#		var token = middle[token_idx]
#		var inc_idx = 1
#
#		var expr_seq = get_expression_sequence(middle, token_size, token_idx)
#		if expr_seq[1] > 1:
#			returns.append({
#				body = "",
#				type = "expression",
#				expr = expr_seq[0],
#				line = token.line
#			})
#			inc_idx = expr_seq[1]
#		else:
#			returns.append(token)
#		token_idx += inc_idx
#	return returns

func _ready():
	var demo: String = read_file("res://src/pipe_script/demo.psl")
	
	parse(demo)
	
