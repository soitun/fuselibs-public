using Uno;

using Fuse.Scripting;

namespace Fuse.Navigation
{
	/**
		Combines the logic for making router navigation requests into one class. This is to ensure
		that the various interfaces `ModifyRoute`, expression `modifyRoute()` and JS `router.modify`
		all behave the same way.
	*/
	class RouterRequest
	{
		public ModifyRouteHow How;
		public RouterPageRoute Route;
		[WeakReference]
		public Node Relative;
		public NavigationGotoMode Transition;
		public string Style;
		public string Bookmark;
		
		[Flags]
		public enum Flags
		{
			None = 0,
			//the path and parameters are specified as a flat array (JS interface)
			FlatRoute = 1 << 0,
		}
		Flags _flags;
		
		public RouterRequest(Flags flags = Flags.None)
		{
			_flags = flags;
			Reset();
		}
		
		public void Reset()
		{
			How = ModifyRouteHow.Goto;
			Route = null;
			Relative = null;
			Transition = NavigationGotoMode.Transition;
			Style = "";
		}
		
		public bool AddHow( ModifyRouteHow how ) 
		{
			How = how;
			return true;
		}
		
		public bool AddPath( object value )
		{
			if (_flags.HasFlag(Flags.FlatRoute))
			{
				var path = value as IArray;
				if (path == null)
				{
					Fuse.Diagnostics.UserError( "`path` should be an array", this );
					return false;
				}
				
				//TODO: convert to bool form like ParseNVPRoute
				Route = ParseFlatRoute(path);
			}
			else
			{
				if (!ParseNVPRoute(value, out Route))
					return false;
			}
			
			return true;
		}
		
		public bool AddArgument(string name, object value)
		{
			if (name == "how")
				return AddHow(Marshal.ToType<ModifyRouteHow>(value));

			if (name == "path")
				return AddPath( value );
			
			if (name == "relative")
			{
				Relative = ParseNode(value);
			}
			else if (name == "transition")
			{
				Transition = Marshal.ToType<NavigationGotoMode>(value);
			}
			else if (name == "bookmark")
			{
				Bookmark = Marshal.ToType<string>(value);
			}
			else if (name == "style")
			{
				Style = Marshal.ToType<string>(value);
			}
			else
			{
				Fuse.Diagnostics.UserError( "Unrecognized argument: " + name, this );
				return false;
			}
			
			return true;
		}
		
		public bool MakeRequest(Router router)
		{
			var targetRoute = Route;
			
			if (Bookmark != null)
			{
				if (targetRoute != null)
				{
					Fuse.Diagnostics.UserError( "A path and bookmark cannot both be specified", router);
					return false;
				}
				
				if (!router.Bookmarks.TryGetValue(Bookmark, out targetRoute))
				{	
					Fuse.Diagnostics.UserError( "Unknown bookmark: " + Bookmark, router);
					return false;
				}
			}
			
			if (Relative != null)
				targetRoute = router.GetRelativeRoute(Relative, targetRoute);
				
			router.Modify( How, targetRoute, Transition, Style );
			return true;
		}

		static public RouterPageRoute ParseFlatRoute(IArray path)
		{
			//TODO: It would make more sense to wrap object[] as an IArray, and rewrite the object[] function
			var cvt = new object[path.Length];
			for (int i=0; i < cvt.Length; ++i)
				cvt[i] = path[i];
			return ParseFlatRoute(cvt);
		}
		
		static public RouterPageRoute ParseFlatRoute(object[] args, int pos = 0)
		{
			if (args.Length <= pos) return null;
			
			var path = args[pos] as string;
			if (path != null)
			{
				if (args.Length <= pos+1) return new RouterPageRoute(
					new RouterPage( args[pos] as string ), null );

				var arg = args[pos+1];

				if (!ValidateParameter(arg, 0)) return null;

				var parameter = Json.Stringify(arg, true);
				return new RouterPageRoute( 
					new RouterPage( path, parameter ), ParseFlatRoute(args, pos+2));
			}
			else
			{
				return new RouterPageRoute(
					new RouterPage( PagesMap.GetObjectPath(args[pos]), null, args[pos] ), 
						ParseFlatRoute(args, pos+1));
			}
		}
		
		/**
			This function decides whether to parse an ObjectRoute or a NVPRoute. It needs to employ a bit of trickery since the UX parser doesn't retain some syntax information, like the different between:
				a:b, c:d
			and
				(a:b, c:d)
			They both end up as the same IObject, which also exposes IArray.
			
			Here we'll assume if the first object, or the first element of the array, contains a path marker, then it's an object path.
		*/
		static internal bool ParseUXRoute(object value, out RouterPageRoute route)
		{
			if (IsObjectRoute(value))
				return ParseObjectRoute(value, out route);
			return ParseNVPRoute(value, out route);
		}
		
		static bool IsObjectRoute(object value)
		{
			var array = value as IArray;
			var isProperArray = array != null && !(value is IObject);
			if (isProperArray && array.Length > 0 && PagesMap.HasObjectPath(array[0]))
				return true;
				
			if (!isProperArray && PagesMap.HasObjectPath(value))
				return true;
				
			return false;
		}
		
		static internal bool ParseObjectRoute(object value, out RouterPageRoute route)
		{
			route = null;
			
			var array = value as IArray;
			var isProperArray = array != null && !(value is IObject);
			if (isProperArray)
			{
				for (int i = array.Length - 1; i >=0; --i)
				{
					if (!ParseObjectComponent(array[i], ref route))
						return false;
				}
				
				return true;
			}
			else
			{
				return ParseObjectComponent(value, ref route);
			}
		}
		
		static bool ParseObjectComponent(object value, ref RouterPageRoute route)
		{
			var path = PagesMap.GetObjectPath(value);
			if (path == null)
			{
				Fuse.Diagnostics.UserError( "Object does not contain a $path", null);
				return false;
			}
			
			route = new RouterPageRoute( new RouterPage( path, null, value), route);
			return true;
		}
		
		static internal bool ParseNVPRoute(object value, out RouterPageRoute route)
		{
			route = null;

			var array = value as IArray;
			if (array != null)
			{
				for (int i = array.Length-1; i>=0; --i)
				{
					if (!ParseNVPComponent(array[i], ref route))
						return false;
				}
				
				return true;
			}
			else
			{
				return ParseNVPComponent(value, ref route);
			}
		}
		
		static bool ParseNVPComponent(object value, ref RouterPageRoute route)
		{
			//require a "string", rather than use TryToType, to avoid nonsense being accepted
			if (value is string)
			{
				route = new RouterPageRoute( new RouterPage( (string)value ),  route);
				return true;
			}
			
			var nvp = value as NameValuePair;
			if (nvp != null)
			{
				route = new RouterPageRoute( new RouterPage( nvp.Name, 
					Json.Stringify(nvp.Value)), route);
				return true;
			}
			
			Fuse.Diagnostics.UserError("incompatible path component", value);
			return false;
		}
		
		static bool ValidateParameter(object arg, int depth = 0)
		{
			if (depth > 50)
			{
				Fuse.Diagnostics.UserError("Route parameter must be serializeable, it contains reference loops or is too large", null);
				return false;
			}

			if (arg is Scripting.Object)
			{
				var obj = (Scripting.Object)arg;
				if (obj is Fuse.Reactive.IObservable)
				{
					Fuse.Diagnostics.UserError("Route parameter must be serializeable, cannot contain Observables.", null);		
					return false;
				}

				var keys = obj.Keys;
				for (var i = 0; i < keys.Length; i++)
				{
					var key = keys[i];
					if (!ValidateParameter(obj[key], depth+1)) return false;
				}
			}

			if (arg is Scripting.Array)
			{
				var arr = (Scripting.Array)arg;
				for (var i = 0; i < arr.Length; i++)
				{
					if (!ValidateParameter(arr[i], depth+1)) return false;
				}
			}

			if (arg is Scripting.Function) 
			{
				Fuse.Diagnostics.UserError("Route parameter must be serializeable, cannot contain functions.", null);
				return false;
			}

			return true;
		}
		
		protected virtual Node ParseNode(object value)
		{
			return value as Node;
		}
		
	}

}
