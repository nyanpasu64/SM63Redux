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
	"true": "boolean",
	"false": "boolean",
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
		"bracket_left": true, # special case, since function calls must start with '('
		"bracket_right": true,
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

# a handy function to check if a string of bytes is alphanumeric (. included)
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
	print()

func create_scope_token(parent, func_name = "?unknown", params = [], guard = [], tokens = []):
	return {
		body = "", # keep this empty
		type = "scope",
		func_id = func_name, # the function name/id
		params = params, # function parameters
		guard_expr = guard, # the function guard
		variables = {}, # defined variables in this function
		funcs = [], # defined functions in this function
		tokens = tokens, # tokens to be interpreted in this function
		parent_scope = parent, # a reference to the parent scope, NOT the previous scope
		handle_expr = [-1, -1, []], # the expression currently being 'compiled'
		args_stack = [] # the stack for storing function arguments
	}

# put tokens from functions into chunks, so it's easier for the interpreter to read
func chunkify_tokens(tokens):
	var token_idx = 0
	var token_size = tokens.size()
	var stack = []
	var scope = create_scope_token(null, ".?")
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
			scope = create_scope_token(scope, func_name, params_data[2], guard[0])
		elif token.type == "func_right":
			token = scope
			scope = stack.pop_back()
		
		if token:
			scope.tokens.append(token)
		
		token_idx += 1
	return scope

func is_literal(token):
	return token.type == "string" || token.type == "atom" || token.type == "number" || token.type == "boolean"

func is_value(token):
	return is_literal(token) || token.type == "call" || token.type == "raw" || token.type == "scope"

# get a variable from the scope
# this function also checks parent scopes for the variable
func get_variable(scope, var_name):
	var search_in_scope = scope
	while search_in_scope:
		if search_in_scope.variables.has(var_name):
			return search_in_scope.variables[var_name]
		search_in_scope = search_in_scope.parent_scope
	printerr("ERROR:\nLine ?: Attempt to access non-existant variable (%s)." % var_name)
	return null

# actually evaluate the provided expression
func handle_expression(scope, global_expr, extra_variables = []):
	# clone the expression, so when we swap variables we don't mutate the global token list
	var expr = []
	for token in global_expr:
		var cloned = {}
		for key in token.keys():
			cloned[key] = token[key]
		expr.append(cloned)
	
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
				item.body = get_variable(scope, item.body).body if get_variable(scope, item.body) else extra_variables[item.body].body
				item.type = "number"
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
		var b = float(expr[best.idx].body)
		var result = 0
		if op == "logic_not":
			result = 0 if b else 1
		else:
			var a = float(expr[best.idx - 2].body)
			
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
	var bracket_pair_count = 0
	var bracket_function_count = 0
	var sequence = []
	var prev_type = "begin"
	var tokens_increased = 0
	while token_idx < token_size:
		var current_type = tokens[token_idx].type
		current_type = "math_" if current_type.begins_with("math_") else current_type
		prev_type = "math_" if prev_type.begins_with("math_") else prev_type
		
		if !expression_acceptance_table.has(prev_type):
			break
		if !expression_acceptance_table[prev_type].has(current_type):
			break
		
		if expression_acceptance_table[prev_type][current_type] && bracket_function_count == 0:
			# if this is a function call, ignore everything until we're outside of the argument range
			if prev_type == "call" && current_type == "bracket_left":
				bracket_function_count = 1
			else:
				if current_type == "bracket_left":
					bracket_pair_count += 1
				elif current_type == "bracket_right":
					bracket_pair_count -= 1
				if bracket_pair_count < 0:
					break
				sequence.append(tokens[token_idx])
		elif bracket_function_count != 0:
			if current_type == "bracket_left":
				bracket_function_count += 1
			elif current_type == "bracket_right":
				bracket_function_count -= 1
			
			# if we exit the argument range, then pretend it didn't exist and say the previous type was call
			if bracket_function_count == 0:
				current_type = "call"
		else:
			break
		
		prev_type = current_type
		token_idx += 1
		tokens_increased += 1
	
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
	return [return_seq, tokens_increased]

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

# calculates how many arguments a function has, and how many tokens it should iterate for them
# returns [iterated tokens, argument count]
func get_argument_count(scope, tokens, token_size, token_idx):
	print("\tARG COUNT START FROM ", token_idx)
	token_idx += 2 # we add 2 to offset from the actual call token
	var iterated_tokens = 2
	var arg_count = 0
	while token_idx < token_size:
		var inc_idx = 1
		var token = tokens[token_idx]
		
		if token.type == "bracket_right":
			iterated_tokens += 1
			break
		elif token.type == "call":
			arg_count += 1
			inc_idx = get_argument_count(scope, tokens, token_size, token_idx)[0]
		else:
			var expr = get_expression_sequence(tokens, token_size, token_idx)
			if expr[0].size() > 1:
				arg_count += 1
				inc_idx = expr[1]
			elif is_value(token):
				arg_count += 1
			
		token_idx += inc_idx
		iterated_tokens += inc_idx
	print("\tARG COUNT END %s %s" % [iterated_tokens, arg_count])
	return [iterated_tokens, arg_count]

# interprets the tokens & executes them
func interpret(scope):
	var root_scope = scope # just in case
	var scope_stack = []
	print_scope(scope)
	
	var return_data = null
	
	var token_idx = 0
	var token_size = scope.tokens.size()
	while token_idx < token_size:
		var token = scope.tokens[token_idx]
		var prev_token = scope.tokens[token_idx - 1] if token_idx > 0 else null
		var dprev_token = scope.tokens[token_idx - 2] if token_idx > 1 else null
		var idx_inc = 1
		
		print(
			"\t".repeat(scope_stack.size()),
			"EXEC: " if scope.handle_expr[0] == -1 else "EXPRESSION: ",
			token_idx, " : ", token.body,
			" (%s)" % token.type
		)
		
		var possible_value = token
		
		var expr_finished = false
		if !return_data:
			# the !return_data check is to prevent function returns creating more expressions
			if scope.handle_expr[0] == -1:
				var expr_seq = get_expression_sequence(scope.tokens, token_size, token_idx)
				if expr_seq[0].size() > 1:
					scope.handle_expr = [token_idx, token_idx + expr_seq[1] - 1, expr_seq]
			elif token_idx == scope.handle_expr[0]:
				idx_inc = scope.handle_expr[2][1]
				possible_value = handle_expression(scope, scope.handle_expr[2][0])
				scope.handle_expr = [-1, -1, []]
				expr_finished = true
			elif token_idx == scope.handle_expr[1]:
				idx_inc -= scope.handle_expr[2][1]
		
		# call the function when we collected all the arguments
		if scope.args_stack.size() > 0 && token_idx == scope.args_stack.back().end_idx && !expr_finished:
		
			var args_dict = scope.args_stack.pop_back()
#			print(args_dict.args, " ", args_dict.begin_idx, " ", args_dict.end_idx)
			
			# switch to the new scope
			scope_stack.append([scope, args_dict.begin_idx])
			scope = args_dict.target_scope
			print(" BEGIN/END %s %s" % [args_dict.begin_idx, args_dict.end_idx])
			
			# inject variables
			for idx in scope.params.size():
				if args_dict.args[idx].type == "scope":
					args_dict.args[idx].func_id = scope.params[idx]
					scope.funcs.append(args_dict.args[idx])
				else:
					scope.variables[scope.params[idx]] = args_dict.args[idx]
					print("  SET VAR: ", scope.params[idx], " = ", args_dict.args[idx])
			print(" ---")
			
			token_size = scope.tokens.size()
			token_idx = 0
			idx_inc = 0
		
#		for k in scope.variables.keys():
#			print("%s: %s" % [k, scope.variables[k]])
		
		if token.type == "call" && !expr_finished:
			# TODO: simplify this function, since we only need the increased amount
			var arg_counts = get_argument_count(scope, scope.tokens, token_size, token_idx)
			
			# if we just returned, don't go back again
			if return_data:
				print("RETURN: ", return_data)
				possible_value = return_data
				return_data = null
				
				# swap expression function calls with their return value
				if scope.handle_expr[0] != -1:
					# find the earliest function call, and swap that
					var actual_expr = scope.handle_expr[2][0]
					for target_idx in actual_expr.size():
						if actual_expr[target_idx].type == "call":
							actual_expr[target_idx] = possible_value
							break
				idx_inc = arg_counts[0]
			else:
				
				# find the function to switch too
				var target_scope
				var search_in_scope = scope
				while search_in_scope:
					for new_scope in search_in_scope.funcs:
						if new_scope.func_id == token.body && new_scope.params.size() == arg_counts[1]:
							#TODO: do the guard check
							#handle_expression(scope, new_scope.guard_expr)
							target_scope = new_scope
							#handle_expression(new_scope.guard_expr)
							break
					if target_scope:
						break
					search_in_scope = search_in_scope.parent_scope
				if target_scope == null:
					printerr(
						"ERROR:\nLine %d: Attempt to call undefined function (%s) with %d given arguments."
						% [
							token.line,
							token.body,
							arg_counts[1]
						])
					break
				
				scope.args_stack.append({
					args = [],
					begin_idx = token_idx,
					end_idx = token_idx + arg_counts[0] - 1,
					target_scope = target_scope
				})
				
				idx_inc = 2
		
		if prev_token && dprev_token && (dprev_token.type == "raw" && !return_data) && prev_token.type == "assign":
			if possible_value.type == "scope":
				# we don't assign functions to variables,
				# we simply change the func_id
				possible_value.func_id = dprev_token.body
				scope.funcs.append(possible_value)
			elif possible_value.type != "call":
				scope.variables[dprev_token.body] = possible_value
		elif token.type == "scope":
			scope.funcs.append(token)
		
		# if we're currently collecting data for function arguments
		# then make to actually store it
		if scope.handle_expr[0] == -1 && (possible_value.type == "string" || possible_value.type == "number"):
			var args_dict = scope.args_stack.back()
			if args_dict && args_dict.end_idx != -1:
#				print("APPEND TO ARGS: ", possible_value)
				args_dict.args.append(possible_value)
#				print("ARGS LIST: ", args_dict.args)
		
		# increment the token index
		token_idx += idx_inc
		
		# if we ran out of instructions, go back a stack
		if token_idx >= token_size && scope_stack.size() > 0:
			# set the return value
			if possible_value.type == "raw":
				possible_value = get_variable(scope, possible_value.body)
			return_data = possible_value
			print("  EXITED FUNCTION (%s) IDX (%s)" % [scope.func_id, token_idx])
			for k in scope.variables.keys():
				print("\t", k, "=", scope.variables[k])
			print("\tRETURNING WITH: ", return_data)
			print("  REAL EXIT")
			
			var prev = scope_stack.pop_back()
			scope = prev[0]
			token_idx = prev[1]
			token_size = scope.tokens.size()
	
	print("\nAppData (VARS):")
	for key in scope.variables.keys():
		print(key, " = ", scope.variables[key])
	print("\nAppData (FUNCS):")
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
					if tokens[token_idx].type != "raw" && tokens[token_idx].type != "anon_func":
						printerr("COMPILE ERROR:\nLine %d: Can only call function names." % tokens[token_idx].line)
						break
					if tokens[token_idx].type == "anon_func":
						tokens[token_idx].body = "?anon_func"
					tokens[token_idx].type = "call"
					make_next_call = false
				# convert atoms into strings
				if tokens[token_idx].type == "atom":
					tokens[token_idx].body = tokens[token_idx].body.substr(1)
					tokens[token_idx].type = "string"
				if tokens[token_idx].type == "boolean":
					tokens[token_idx].body = 1 if tokens[token_idx].body == "true" else 0
					tokens[token_idx].type = "number"
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
	
