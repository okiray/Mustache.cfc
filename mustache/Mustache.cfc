<cfcomponent output="false">
	<!---
		reference for string building
		http://www.aliaspooryorik.com/blog/index.cfm/e/posts.details/post/string-concatenation-performance-test-128
	 --->

	<!--- captures the ".*" match for looking for formatters (see #2) and also allows nested structure references (see #3), removes looking for comments --->
	<cfset variables.TagRegEx = createObject("java","java.util.regex.Pattern").compile("\{\{(\{|&|\>)?\s*(\w+(?:(?:\.\w+){1,})?)(.*?)\}?\}\}", 32)/>
	<!--- captures nested structure references (see #3) --->
	<cfset variables.SectionRegEx = createObject("java","java.util.regex.Pattern").compile("\{\{(##|\^)\s*(\w+(?:(?:\.\w+){1,})?)\s*}}(.*?)\{\{/\s*\2\s*\}\}", 32)/>
	<!--- captures nested structure references (see #3) --->
	<cfset variables.CommentRegEx = createObject("java","java.util.regex.Pattern").compile("((^\r?\n?)|\s+)?\{\{!.*?\}\}(\r?\n?(\r?\n?)?)?", 40)/>
	<!--- captures nested structure references (see #3) --->
	<cfset variables.HeadTailBlankLinesRegEx = createObject("java","java.util.regex.Pattern").compile(javaCast("string", "(^(\r?\n))|((?<!(\r?\n))(\r?\n)$)"), 32)/>
	<!--- for tracking partials --->
	<cfset variables.partials = {}/>

	<cffunction name="init" access="public" output="false"
		hint="initalizes and returns the object">
		<cfargument name="partials" hint="the partial objects" default="#StructNew()#">

		<cfset setPartials(arguments.partials)/>

		<cfreturn this/>
	</cffunction>

	<cffunction name="render" access="public" output="false"
		hint="main function to call to a new template">
		<cfargument name="template" default="#readMustacheFile(ListLast(getMetaData(this).name, '.'))#"/>
		<cfargument name="context" default="#this#"/>
		<cfargument name="partials" hint="the partial objects" required="true" default="#structNew()#"/>
		<cfset var results = renderFragment(argumentCollection=arguments)/>

		<!--- remove single blank lines at the head/tail of the stream --->
		<cfset results = variables.HeadTailBlankLinesRegEx.matcher(javaCast("string", results)).replaceAll("")/>

		<cfreturn results/>
	</cffunction>

	<cffunction name="renderFragment" access="private" output="false"
		hint="handles all the various fragments of the template">
		<cfargument name="template"/>
		<cfargument name="context"/>
		<cfargument name="partials" hint="the partial objects" required="true" default="#structNew()#"/>

		<!--- clean the comments from the template --->
		<cfset arguments.template = variables.CommentRegEx.matcher(javaCast("string", arguments.template)).replaceAll("$3")/>

		<cfset structAppend(arguments.partials, variables.partials, false)/>
		<cfset arguments.template = renderSections(arguments.template, arguments.context, arguments.partials)/>
		<cfreturn renderTags(arguments.template, arguments.context, arguments.partials)/>
	</cffunction>

	<cffunction name="renderSections" access="private" output="false">
		<cfargument name="template"/>
		<cfargument name="context"/>
		<cfargument name="partials"/>
		<cfset var loc = {}/>
	
		<cfloop condition = "true">
		
			<cfset loc.matches = ReFindNoCaseValues(arguments.template, variables.SectionRegEx)/>
		
			<cfif arrayLen(loc.matches) eq 0>
				<cfbreak/>
			</cfif>
	
			<cfset loc.tag = loc.matches[1]/>
			<cfset loc.type = loc.matches[2]/>
			<cfset loc.tagName = loc.matches[3]/>
			<cfset loc.inner = loc.matches[4]/>
			<cfset loc.rendered = renderSection(loc.tagName, loc.type, loc.inner, arguments.context, arguments.partials)/>
	
			<!--- trims out empty lines from appearing in the output --->
			<cfif len(trim(loc.rendered)) eq 0>
				<cfset loc.rendered = "$2"/>
			<cfelse>
				<!--- escape the backreference --->
				<cfset loc.rendered = replace(loc.rendered, "$", "\$", "all")/>
			</cfif>
	
			<!--- we use a regex to remove unwanted whitespacing from appearing --->
			<cfset arguments.template = createObject("java","java.util.regex.Pattern").compile(javaCast("string", "(^\r?\n?)?(\r?\n?)?\Q" & loc.tag & "\E(\r?\n?)?"), 40).matcher(javaCast("string", arguments.template)).replaceAll(loc.rendered)/>
		</cfloop>
		
		<cfreturn arguments.template/>
	</cffunction>

	<cffunction name="renderSection" access="private" output="false">
		<cfargument name="tagName"/>
		<cfargument name="type"/>
		<cfargument name="inner"/>
		<cfargument name="context"/>
		<cfargument name="partials"/>
		<cfset var loc = {}>

		<cfset loc.ctx = get(arguments.tagName, arguments.context, arguments.partials)/>

		<cfif arguments.type neq "^" and isStruct(loc.ctx) and !StructIsEmpty(loc.ctx)>
			<cfreturn renderFragment(arguments.inner, loc.ctx, arguments.partials)/>
		<cfelseif arguments.type neq "^" and isQuery(loc.ctx) AND loc.ctx.recordCount>
			<cfreturn renderQuerySection(arguments.inner, loc.ctx, arguments.partials)/>
		<cfelseif arguments.type neq "^" and isArray(loc.ctx) and !ArrayIsEmpty(loc.ctx)>
			<cfreturn renderArraySection(arguments.inner, loc.ctx, arguments.partials)/>
		<cfelseif arguments.type neq "^" and structKeyExists(arguments.context, arguments.tagName) and isCustomFunction(arguments.context[arguments.tagName])>
			<cfreturn renderLambda(arguments.tagName, arguments.inner, arguments.context, arguments.partials)/>
		</cfif>

		<cfif arguments.type eq "^" xor convertToBoolean(loc.ctx)>
			<cfreturn arguments.inner/>
		</cfif>
		
		<cfreturn ""/>
	</cffunction>

	<cffunction name="renderLambda" access="private" output="false"
		hint="render a lambda function (also provides a hook if you want to extend how lambdas works)">
		<cfargument name="tagName"/>
		<cfargument name="template" />
		<cfargument name="context" />
		<cfargument name="partials"/>
		<cfset var local = {} />

		<!---// if running on a component //--->
		<cfif isObject(arguments.context)>
			<!---// call the function and pass in the arguments //--->
			<cfinvoke component="#arguments.context#" method="#arguments.tagName#" returnvariable="local.results">
				<cfinvokeargument name="1" value="#arguments.template#">
			</cfinvoke>
		<!---// otherwise we have a struct w/a reference to a function or closure //--->
		<cfelse>
			<cfset local.fn = arguments.context[arguments.tagName] />
			<cfset local.results = local.fn(arguments.template) />
		</cfif>

		<cfreturn local.results />
	</cffunction>

	<cffunction name="convertToBoolean">
		<cfargument name="value"/>

		<cfif isBoolean(arguments.value)>
			<cfreturn arguments.value/>
		</cfif>
		<cfif IsSimpleValue(arguments.value)>
			<cfreturn arguments.value neq ""/>
		</cfif>
		<cfif isStruct(arguments.value)>
			<cfreturn !StructIsEmpty(arguments.value)>
		</cfif>
		<cfif isQuery(arguments.value)>
			<cfreturn arguments.value.recordcount neq 0>
		</cfif>
		<cfif isArray(arguments.value)>
			<cfreturn !ArrayIsEmpty(arguments.value)>
		</cfif>

		<cfreturn false>
	</cffunction>

	<cffunction name="renderQuerySection" access="private" output="false">
		<cfargument name="template"/>
		<cfargument name="context"/>
		<cfargument name="partials"/>
		<cfset var result = []/>

		<!--- trim the trailing whitespace--so we don't print extra lines --->
		<cfset arguments.template = rtrim(arguments.template)/>

		<cfloop query="arguments.context">
			<cfset ArrayAppend(result, renderFragment(arguments.template, arguments.context, arguments.partials))/>
		</cfloop>
		<cfreturn ArrayToList(result, "")/>
	</cffunction>

	<cffunction name="renderArraySection" access="private" output="false">
		<cfargument name="template"/>
		<cfargument name="context"/>
		<cfargument name="partials"/>
		<cfset var loc = {}>

		<!--- trim the trailing whitespace--so we don't print extra lines --->
		<cfset arguments.template = rtrim(arguments.template)/>

		<cfset loc.result = []/>
		<cfloop array="#arguments.context#" index="loc.item">
			<cfset ArrayAppend(loc.result, renderFragment(arguments.template, loc.item, arguments.partials))/>
		</cfloop>
		<cfreturn ArrayToList(loc.result, "")/>
	</cffunction>

	<cffunction name="renderTags" access="private" output="false">
		<cfargument name="template"/>
		<cfargument name="context"/>
		<cfargument name="partials"/>
		<cfset var loc = {}/>
	
		<cfloop condition = "true" >
			
			<cfset loc.matches = ReFindNoCaseValues(arguments.template, variables.TagRegEx)/>
			
			<cfif arrayLen(loc.matches) eq 0>
				<cfbreak/>
			</cfif>

			<cfset loc.tag = loc.matches[1]/>
			<cfset loc.type = loc.matches[2]/>
			<cfset loc.tagName = loc.matches[3]/>
			<!--- gets the ".*" capture --->
			<cfset loc.extra = loc.matches[4]/>
			<cfset arguments.template = replace(arguments.template, loc.tag, renderTag(loc.type, loc.tagName, arguments.context, arguments.partials, loc.extra))/>
			
		</cfloop>

		<cfreturn arguments.template/>
	</cffunction>

	<cffunction name="renderTag" access="private" output="false">
		<cfargument name="type"/>
		<cfargument name="tagName"/>
		<cfargument name="context"/>
		<cfargument name="partials"/>
		<cfargument name="extra" hint="The text appearing after the tag name"/>
		<cfset var loc = {}/>
		<cfset var results = ""/>
		<cfset var extras = listToArray(arguments.extra, ":")/>
		
		<cfif arguments.type eq "!">
			<cfreturn "">
		<cfelseif (arguments.type eq "{") or (arguments.type eq "&")>
			<cfset results = get(arguments.tagName, arguments.context, arguments.partials)/>
		<cfelseif arguments.type eq ">">
			<cfset results = renderPartial(arguments.tagName, arguments.context, arguments.partials)/>
		<cfelse>
			<cfset results = htmlEditFormat(get(arguments.tagName, arguments.context, arguments.partials))/>
		</cfif>
		
		<cfreturn onRenderTag(results, arguments)/>
	</cffunction>

	<cffunction name="onRenderTag" access="private" output="false"
		hint="override this function in your methods to provide additional formatting to rendered content">
		<cfargument name="rendered"/>
		<cfargument name="options" hint="Arguments supplied to the renderTag() function"/>
		<!--- do nothing but return the passed in value --->
		<cfreturn arguments.rendered/>
	</cffunction>

	<cffunction name="renderPartial"  access="private" output="false"
		hint="If we have the partial registered, use that, otherwise use the registered text">
		<cfargument name="name" hint="the name of the partial" required="true">
		<cfargument name="context" hint="the context" required="true">
		<cfargument name="partials" hint="the partial objects" required="true">

		<cfif structKeyExists(arguments.partials, arguments.name)>
			<cfreturn render(arguments.partials[arguments.name], arguments.context, arguments.partials)/>
		<cfelse>
			<cfreturn render(readMustacheFile(arguments.name), arguments.context, arguments.partials)/>
		</cfif>

	</cffunction>

	<cffunction name="readMustacheFile" access="private" output="false">
		<cfargument name="filename"/>
		<cfset var template= ""/>
		<cffile action="read" file="#getDirectoryFromPath(getMetaData(this).path)##arguments.filename#.mustache" variable="template"/>
		<cfreturn trim(template)/>
	</cffunction>

	<cffunction name="get" access="private" output="false">
		<cfargument name="key"/>
		<cfargument name="context"/>
		<cfargument name="partials"/>
		<cfset var loc = {}/>

		<!--- if we're a nested key, do a nested lookup --->
		<cfif find(".", arguments.key)>
			<cfset loc.key = listRest(arguments.key, ".")/>
			<cfset loc.root = listFirst(arguments.key, ".")/>
			<cfif structKeyExists(arguments.context, loc.root)>
				<cfreturn get(loc.key, context[loc.root], arguments.partials)/>
			<cfelse>
				<cfreturn ""/>
			</cfif>
		<cfelseif isStruct(arguments.context) && structKeyExists(arguments.context, arguments.key) >
			<cfif isCustomFunction(arguments.context[arguments.key])>
				<cfreturn renderLambda(arguments.key, '', arguments.context, arguments.partials)/>
			<cfelse>
				<cfreturn arguments.context[arguments.key]/>
			</cfif>
		<cfelseif isQuery(arguments.context)>
			<cfif listContainsNoCase(arguments.context.columnList, arguments.key)>
				<cfreturn arguments.context[arguments.key][arguments.context.currentrow]/>
			<cfelse>
				<cfreturn ""/>
			</cfif>
		<cfelse>
			<cfreturn ""/>
		</cfif>
	</cffunction>

	<cffunction name="ReFindNoCaseValues" access="private" output="false">
		<cfargument name="text"/>
		<cfargument name="re"/>
		<cfset var loc = {}>

		<cfset loc.results = []/>
		<cfset loc.matcher = arguments.re.matcher(arguments.text)/>
		<cfset loc.i = 0/>
		<cfset loc.nextMatch = ""/>
		<cfif loc.matcher.Find()>
			<cfloop index="loc.i" from="0" to="#loc.matcher.groupCount()#">
				<cfset loc.nextMatch = loc.matcher.group(loc.i)/>
				<cfif isDefined('loc.nextMatch')>
					<cfset arrayAppend(loc.results, loc.nextMatch)/>
				<cfelse>
					<cfset arrayAppend(loc.results, "")/>
				</cfif>
			</cfloop>
		</cfif>

		<cfreturn loc.results/>
	</cffunction>

	<cffunction name="getPartials" access="public" output="false">
		<cfreturn variables.partials/>
	</cffunction>

	<cffunction name="setPartials" access="public" output="false">
		<cfargument name="partials" required="true">
		<cfset variables.partials = arguments.partials/>
	</cffunction>

</cfcomponent>
