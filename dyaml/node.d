
//          Copyright Ferdinand Majerech 2011.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)

/**
 * Node of a YAML document. Used to read YAML data once it's loaded,
 * and to prepare data to emit.
 */
module dyaml.node;


import std.algorithm;
import std.conv;
import std.datetime;
import std.exception;
import std.math;
import std.range;
import std.stdio;   
import std.string;
import std.traits;
import std.typecons;
import std.variant;

import dyaml.event;
import dyaml.exception;
import dyaml.style;
import dyaml.tag;


///Exception thrown at node related errors.
class NodeException : YAMLException
{
    package:
        /*
         * Construct a NodeException.
         *
         * Params:  msg   = Error message.
         *          start = Start position of the node.
         */
        this(string msg, Mark start, string file = __FILE__, int line = __LINE__)
        {
            super(msg ~ "\nNode at: " ~ start.toString(), file, line);
        }
}

private alias NodeException Error;

//Node kinds.
package enum NodeID : ubyte
{
    Scalar,
    Sequence,
    Mapping
}

///Null YAML type. Used in nodes with _null values.
struct YAMLNull
{
    ///Used for string conversion.
    string toString() const {return "null";}
}

//Merge YAML type, used to support "tag:yaml.org,2002:merge".
package struct YAMLMerge{}

//Base class for YAMLContainer - used for user defined YAML types.
package abstract class YAMLObject
{
    public:
        ///Get type of the stored value.
        @property TypeInfo type() const {assert(false);}

    protected:
        ///Test for equality with another YAMLObject.
        bool equals(const YAMLObject rhs) const {assert(false);} 
}

//Stores a user defined YAML data type.
package class YAMLContainer(T) if (!Node.Value.allowed!T): YAMLObject
{
    private:
        //Stored value.
        T value_;

    public:
        //Get type of the stored value.
        @property override TypeInfo type() const {return typeid(T);}

        //Get string representation of the container.
        override string toString()
        {
            static if(!hasMember!(T, "toString"))
            {
                return super.toString();
            }
            else
            {
                return format("YAMLContainer(", value_.toString(), ")");
            }
        }

    protected:
        //Test for equality with another YAMLObject.
        override bool equals(const YAMLObject rhs) const
        {
            if(rhs.type !is typeid(T)){return false;}
            return cast(T)value_ == (cast(const YAMLContainer)rhs).value_;
        }

    private:
        //Construct a YAMLContainer holding specified value.
        this(T value){value_ = value;}
}


/**
 * YAML node.
 *
 * This is a pseudo-dynamic type that can store any YAML value, including a 
 * sequence or mapping of nodes. You can get data from a Node directly or 
 * iterate over it if it's a collection.
 */
struct Node
{
    public:
        ///Key-value pair of YAML nodes, used in mappings.
        struct Pair
        {
            public:
                ///Key node.
                Node key;
                ///Value node.
                Node value;

            public:
                @disable int opCmp(ref Pair);

                ///Construct a Pair from two values. Will be converted to Nodes if needed.
                this(K, V)(K key, V value)
                {
                    static if(is(Unqual!K == Node)){this.key = key;}
                    else                           {this.key = Node(key);}
                    static if(is(Unqual!V == Node)){this.value = value;}
                    else                           {this.value = Node(value);}
                }

                ///Equality test with another Pair.
                bool opEquals(const ref Pair rhs) const
                {
                    return equals!true(rhs);
                } 

            private:
                /* 
                 * Equality test with another Pair.
                 *
                 * useTag determines whether or not we consider node tags 
                 * in the test.
                 */
                bool equals(bool useTag)(ref const(Pair) rhs) const
                {
                    return key.equals!(useTag)(rhs.key) && 
                           value.equals!(useTag)(rhs.value);
                }
        }

    package:
        //YAML value type.
        alias Algebraic!(YAMLNull, YAMLMerge, bool, long, real, ubyte[], SysTime, string,
                         Node.Pair[], Node[], YAMLObject) Value;

    private:
        ///Stored value.
        Value value_;
        ///Start position of the node.
        Mark startMark_;

    package:
        //Tag of the node. 
        Tag tag_;
        //Node scalar style. Used to remember style this node was loaded with.
        ScalarStyle scalarStyle = ScalarStyle.Invalid;
        //Node collection style. Used to remember style this node was loaded with.
        CollectionStyle collectionStyle = CollectionStyle.Invalid;

    public:
        @disable int opCmp(ref Node);

        /**
         * Construct a Node from a value.
         *
         * Any type except of Node can be stored in a Node, but default YAML 
         * types (integers, floats, strings, timestamps, etc.) will be stored
         * more efficiently. 
         *
         *
         * Note that to emit any non-default types you store 
         * in a node, you need a Representer to represent them in YAML -
         * otherwise emitting will fail.
         *
         * Params:  value = Value to store in the node.
         *          tag   = Overrides tag of the node when emitted, regardless 
         *                  of tag determined by Representer. Representer uses
         *                  this to determine YAML data type when a D data type 
         *                  maps to multiple different YAML data types. Tag must 
         *                  be in full form, e.g. "tag:yaml.org,2002:int", not 
         *                  a shortcut, like "!!int".            
         */
        this(T)(T value, in string tag = null) if (isSomeString!T || 
                                                  (!isArray!T && !isAssociativeArray!T))
        {
            tag_ = Tag(tag);

            //No copyconstruction.
            static assert(!is(Unqual!T == Node));

            //We can easily convert ints, floats, strings.
            static if(isIntegral!T)          {value_ = Value(cast(long) value);}
            else static if(isFloatingPoint!T){value_ = Value(cast(real) value);}
            else static if(isSomeString!T)   {value_ = Value(to!string(value));}
            //Other directly supported type.
            else static if(Value.allowed!T)  {value_ = Value(value);}
            //User defined type.
            else                             {value_ = userValue(value);}
        }
        unittest
        {
            with(Node(42))
            {
                assert(isScalar() && !isSequence && !isMapping && !isUserType);
                assert(as!int == 42 && as!float == 42.0f && as!string == "42");
                assert(!isUserType());
            }
            with(Node(new class{int a = 5;}))
            {
                assert(isUserType());
            }
        }

        /**
         * Construct a node from an _array.
         *
         * If _array is an _array of nodes or pairs, it is stored directly. 
         * Otherwise, every value in the array is converted to a node, and 
         * those nodes are stored.
         *
         * Params:  array = Values to store in the node.
         *          tag   = Overrides tag of the node when emitted, regardless 
         *                  of tag determined by Representer. Representer uses
         *                  this to determine YAML data type when a D data type 
         *                  maps to multiple different YAML data types.
         *                  This is used to differentiate between YAML sequences 
         *                  ("!!seq") and sets ("!!set"), which both are 
         *                  internally represented as an array_ of nodes. Tag 
         *                  must be in full form, e.g. "tag:yaml.org,2002:set",
         *                  not a shortcut, like "!!set".
         *
         * Examples:
         * --------------------
         * //Will be emitted as a sequence (default for arrays)
         * auto seq = Node([1, 2, 3, 4, 5]);
         * //Will be emitted as a set (overriden tag)
         * auto set = Node([1, 2, 3, 4, 5], "tag:yaml.org,2002:set");
         * --------------------
         */
        this(T)(T[] array, in string tag = null) if (!isSomeString!(T[]))
        {
            tag_ = Tag(tag);

            //Construction from raw node or pair array.
            static if(is(Unqual!T == Node) || is(Unqual!T == Node.Pair))
            {
                value_ = Value(array);
            }
            //Need to handle byte buffers separately.
            else static if(is(Unqual!T == byte) || is(Unqual!T == ubyte))
            {
                value_ = Value(cast(ubyte[]) array);
            }
            else
            {
                Node[] nodes;
                foreach(ref value; array){nodes ~= Node(value);}
                value_ = Value(nodes);
            }
        }
        unittest
        {
            with(Node([1, 2, 3]))
            {
                assert(!isScalar() && isSequence && !isMapping && !isUserType);
                assert(length == 3);
                assert(opIndex(2).as!int == 3);
            }

            //Will be emitted as a sequence (default for arrays)
            auto seq = Node([1, 2, 3, 4, 5]);
            //Will be emitted as a set (overriden tag)
            auto set = Node([1, 2, 3, 4, 5], "tag:yaml.org,2002:set");
        }

        /**
         * Construct a node from an associative _array.
         *
         * If keys and/or values of _array are nodes, they stored directly. 
         * Otherwise they are converted to nodes and then stored.
         *
         * Params:  array = Values to store in the node.
         *          tag   = Overrides tag of the node when emitted, regardless 
         *                  of tag determined by Representer. Representer uses
         *                  this to determine YAML data type when a D data type 
         *                  maps to multiple different YAML data types.
         *                  This is used to differentiate between YAML unordered 
         *                  mappings ("!!map"), ordered mappings ("!!omap"), and 
         *                  pairs ("!!pairs") which are all internally 
         *                  represented as an _array of node pairs. Tag must be 
         *                  in full form, e.g. "tag:yaml.org,2002:omap", not a
         *                  shortcut, like "!!omap".
         *
         * Examples:
         * --------------------
         * //Will be emitted as an unordered mapping (default for mappings)
         * auto map   = Node([1 : "a", 2 : "b"]);
         * //Will be emitted as an ordered map (overriden tag)
         * auto omap  = Node([1 : "a", 2 : "b"], "tag:yaml.org,2002:omap");
         * //Will be emitted as pairs (overriden tag)
         * auto pairs = Node([1 : "a", 2 : "b"], "tag:yaml.org,2002:pairs");
         * --------------------
         */
        this(K, V)(V[K] array, in string tag = null)
        {
            tag_ = Tag(tag);

            Node.Pair[] pairs;
            foreach(key, ref value; array){pairs ~= Pair(key, value);}
            value_ = Value(pairs);
        }
        unittest
        {
            int[string] aa;
            aa["1"] = 1;
            aa["2"] = 2;
            with(Node(aa))
            {
                assert(!isScalar() && !isSequence && isMapping && !isUserType);
                assert(length == 2);
                assert(opIndex("2").as!int == 2);
            }

            //Will be emitted as an unordered mapping (default for mappings)
            auto map   = Node([1 : "a", 2 : "b"]);
            //Will be emitted as an ordered map (overriden tag)
            auto omap  = Node([1 : "a", 2 : "b"], "tag:yaml.org,2002:omap");
            //Will be emitted as pairs (overriden tag)
            auto pairs = Node([1 : "a", 2 : "b"], "tag:yaml.org,2002:pairs");
        }

        /**
         * Construct a node from arrays of _keys and _values.
         *
         * Constructs a mapping node with key-value pairs from
         * _keys and _values, keeping their order. Useful when order
         * is important (ordered maps, pairs).
         *
         *
         * keys and values must have equal length.
         *
         *
         * If _keys and/or _values are nodes, they are stored directly/
         * Otherwise they are converted to nodes and then stored.
         *
         * Params:  keys   = Keys of the mapping, from first to last pair.
         *          values = Values of the mapping, from first to last pair.
         *          tag    = Overrides tag of the node when emitted, regardless 
         *                   of tag determined by Representer. Representer uses
         *                   this to determine YAML data type when a D data type 
         *                   maps to multiple different YAML data types.
         *                   This is used to differentiate between YAML unordered 
         *                   mappings ("!!map"), ordered mappings ("!!omap"), and 
         *                   pairs ("!!pairs") which are all internally 
         *                   represented as an array of node pairs. Tag must be 
         *                   in full form, e.g. "tag:yaml.org,2002:omap", not a 
         *                   shortcut, like "!!omap".
         *
         * Examples:
         * --------------------
         * //Will be emitted as an unordered mapping (default for mappings)
         * auto map   = Node([1, 2], ["a", "b"]);
         * //Will be emitted as an ordered map (overriden tag)
         * auto omap  = Node([1, 2], ["a", "b"], "tag:yaml.org,2002:omap");
         * //Will be emitted as pairs (overriden tag)
         * auto pairs = Node([1, 2], ["a", "b"], "tag:yaml.org,2002:pairs");
         * --------------------
         */
        this(K, V)(K[] keys, V[] values, in string tag = null) 
            if(!(isSomeString!(K[]) || isSomeString!(V[])))
        in
        {
            assert(keys.length == values.length, 
                   "Lengths of keys and values arrays to construct "
                   "a YAML node from don't match");
        }
        body
        {
            tag_ = Tag(tag);

            Node.Pair[] pairs;
            foreach(i; 0 .. keys.length){pairs ~= Pair(keys[i], values[i]);}
            value_ = Value(pairs);
        }
        unittest
        {
            with(Node(["1", "2"], [1, 2]))
            {
                assert(!isScalar() && !isSequence && isMapping && !isUserType);
                assert(length == 2);
                assert(opIndex("2").as!int == 2);
            }

            //Will be emitted as an unordered mapping (default for mappings)
            auto map   = Node([1, 2], ["a", "b"]);
            //Will be emitted as an ordered map (overriden tag)
            auto omap  = Node([1, 2], ["a", "b"], "tag:yaml.org,2002:omap");
            //Will be emitted as pairs (overriden tag)
            auto pairs = Node([1, 2], ["a", "b"], "tag:yaml.org,2002:pairs");
        }

        ///Is this node valid (initialized)? 
        @property bool isValid()    const {return value_.hasValue;}
                                            
        ///Is this node a scalar value?
        @property bool isScalar()   const {return !(isMapping || isSequence);}
                                            
        ///Is this node a sequence?
        @property bool isSequence() const {return isType!(Node[]);}
                                            
        ///Is this node a mapping?
        @property bool isMapping()  const {return isType!(Pair[]);}

        ///Is this node a user defined type?
        @property bool isUserType() const {return isType!YAMLObject;}

        ///Return tag of the node.
        @property string tag()      const {return tag_.get;}

        /**
         * Equality test.
         *
         * If T is Node, recursively compare all subnodes. 
         * This might be quite expensive if testing entire documents.
         *
         * If T is not Node, convert the node to T and test equality with that.
         *
         * Examples:
         * --------------------
         * auto node = Node(42);
         *
         * assert(node == 42);
         * assert(node == "42");
         * assert(node != "43");
         * --------------------
         *
         * Params:  rhs = Variable to test equality with.
         *
         * Returns: true if equal, false otherwise.
         */
        bool opEquals(T)(const ref T rhs) const
        {
            return equals!true(rhs);
        }

        ///Shortcut for get().
        alias get as;

        /**
         * Get the value of the node as specified type.
         *
         * If the specifed type does not match type in the node,
         * conversion is attempted.
         *
         * Numeric values are range checked, throwing if out of range of 
         * requested type.
         *
         * Timestamps are stored as std.datetime.SysTime.
         * Binary values are decoded and stored as ubyte[]. 
         *
         * $(BR)$(B Mapping default values:)
         * 
         * $(PBR
         * The '=' key can be used to denote the default value of a mapping.
         * This can be used when a node is scalar in early versions of a program, 
         * but is replaced by a mapping later. Even if the node is a mapping, the
         * get method can be used as if it was a scalar if it has a default value. 
         * This way, new YAML files where the node is a mapping can still be read
         * by old versions of the program, which expect the node to be a scalar.
         * )
         *
         * Examples:
         *
         * Automatic type conversion:
         * --------------------
         * auto node = Node(42);
         *
         * assert(node.as!int == 42);
         * assert(node.as!string == "42");
         * assert(node.as!double == 42.0);
         * --------------------
         *
         * Returns: Value of the node as specified type.
         *
         * Throws:  NodeException if unable to convert to specified type, or if
         *          the value is out of range of requested type.
         */
        @property T get(T)() if(!is(T == const))
        {
            if(isType!T){return value_.get!T;}

            ///Must go before others, as even string/int/etc could be stored in a YAMLObject.
            static if(!Value.allowed!T) if(isUserType)
            {
                auto object = as!YAMLObject;
                if(object.type is typeid(T))
                {
                    return (cast(YAMLContainer!T)object).value_;
                }
                throw new Error("Node has unexpected type: " ~ object.type.toString ~ 
                                ". Expected: " ~ typeid(T).toString, startMark_);
            }

            //If we're getting from a mapping and we're not getting Node.Pair[],
            //we're getting the default value.
            if(isMapping){return this["="].as!T;}

            static if(isSomeString!T)
            {
                //Try to convert to string.
                try
                {
                    return value_.coerce!T();
                }
                catch(VariantException e)
                {
                    throw new Error("Unable to convert node value to string", startMark_);
                }
            }
            else 
            {
                static if(isFloatingPoint!T)
                {
                    ///Can convert int to float.
                    if(isInt())       {return to!T(value_.get!(const long));}
                    else if(isFloat()){return to!T(value_.get!(const real));}
                }
                else static if(isIntegral!T) if(isInt())
                {                
                    const temp = value_.get!(const long);
                    enforce(temp >= T.min && temp <= T.max,
                            new Error("Integer value of type " ~ typeid(T).toString ~ 
                                      " out of range. Value: " ~ to!string(temp), startMark_));
                    return to!T(temp);
                }
                throw new Error("Node has unexpected type: " ~ type.toString ~ 
                                ". Expected: " ~ typeid(T).toString, startMark_);
            }
        }

        //Const version of get.
        @property T get(T)() const if(is(T == const))
        {
            if(isType!T){return value_.get!T;}

            ///Must go before others, as even string/int/etc could be stored in a YAMLObject.
            static if(!Value.allowed!T) if(isUserType)
            {
                auto object = as!(const YAMLObject);
                if(object.type is typeid(T))
                {
                    return (cast(const YAMLContainer!T)object).value_;
                }
                throw new Error("Node has unexpected type: " ~ object.type.toString ~ 
                                ". Expected: " ~ typeid(T).toString, startMark_);
            }

            //If we're getting from a mapping and we're not getting Node.Pair[],
            //we're getting the default value.
            if(isMapping){return indexConst("=").as!T;}

            static if(isSomeString!T)
            {
                //Try to convert to string.
                try
                {
                    //NOTE: We are casting away const here
                    return (cast(Value)value_).coerce!T();
                }
                catch(VariantException e)
                {
                    throw new Error("Unable to convert node value to string", startMark_);
                }
            }
            else 
            {
                static if(isFloatingPoint!T)
                {
                    ///Can convert int to float.
                    if(isInt())       {return to!T(value_.get!(const long));}
                    else if(isFloat()){return to!T(value_.get!(const real));}
                }
                else static if(isIntegral!T) if(isInt())
                {                
                    const temp = value_.get!(const long);
                    enforce(temp >= T.min && temp <= T.max,
                            new Error("Integer value of type " ~ typeid(T).toString ~ 
                                      " out of range. Value: " ~ to!string(temp), startMark_));
                    return to!T(temp);
                }
                throw new Error("Node has unexpected type: " ~ type.toString ~ 
                                ". Expected: " ~ typeid(T).toString, startMark_);
            }
        }

        /**
         * If this is a collection, return its _length.
         *
         * Otherwise, throw NodeException.
         *
         * Returns: Number of elements in a sequence or key-value pairs in a mapping.
         *
         * Throws: NodeException if this is not a sequence nor a mapping.
         */
        @property size_t length() const
        {
            if(isSequence)    {return value_.get!(const Node[]).length;}
            else if(isMapping){return value_.get!(const Pair[]).length;}
            throw new Error("Trying to get length of a scalar node", startMark_);
        }

        /**
         * Get the element at specified index.
         *
         * If the node is a sequence, index must be integral.
         *
         *
         * If the node is a mapping, return the value corresponding to the first 
         * key equal to index, even after conversion. I.e; node["12"] will 
         * return value of the first key that equals "12", even if it's an integer.
         *
         * Params:  index = Index to use.
         *
         * Returns: Value corresponding to the index.
         *
         * Throws:  NodeException if the index could not be found,
         *          non-integral index is used with a sequence or the node is
         *          not a collection.
         */
        ref Node opIndex(T)(T index)
        {
            if(isSequence)
            {
                checkSequenceIndex(index);
                static if(isIntegral!T)
                {
                    return cast(Node)value_.get!(Node[])[index];
                }
                assert(false);
            }
            else if(isMapping)
            {
                auto idx = findPair(index);
                if(idx >= 0)
                {
                    return cast(Node)value_.get!(Pair[])[idx].value;
                }

                string msg = "Mapping index not found" ~ (isSomeString!T ? ": " ~ to!string(index) : "");
                throw new Error(msg, startMark_);
            }
            throw new Error("Trying to index node that does not support indexing", startMark_);
        }
        unittest
        {
            writeln("D:YAML Node opIndex unittest");

            alias Node.Value Value;
            alias Node.Pair Pair;
            Node n1 = Node(cast(long)11);
            Node n2 = Node(cast(long)12);
            Node n3 = Node(cast(long)13);
            Node n4 = Node(cast(long)14);

            Node k1 = Node("11");
            Node k2 = Node("12");
            Node k3 = Node("13");
            Node k4 = Node("14");

            Node narray = Node([n1, n2, n3, n4]);
            Node nmap   = Node([Pair(k1, n1),
                                Pair(k2, n2),  
                                Pair(k3, n3),  
                                Pair(k4, n4)]);

            assert(narray[0].as!int == 11);
            assert(null !is collectException(narray[42]));
            assert(nmap["11"].as!int == 11);
            assert(nmap["14"].as!int == 14);
            assert(null !is collectException(nmap["42"]));
        }

        /**
         * Set element at specified index in a collection.
         *
         * This method can only be called on collection nodes.
         * 
         * If the node is a sequence, index must be integral.
         *
         * If the node is a mapping, sets the _value corresponding to the first 
         * key matching index (including conversion, so e.g. "42" matches 42).
         * 
         * If the node is a mapping and no key matches index, a new key-value
         * pair is added to the mapping. In sequences the index must be in 
         * range. This ensures behavior siilar to D arrays and associative 
         * arrays.
         *
         * Params:  index = Index of the value to set.
         *
         * Throws:  NodeException if the node is not a collection, index is out
         *          of range or if a non-integral index is used on a sequence node.
         */
        void opIndexAssign(K, V)(V value, K index)
        {
            if(isSequence())
            {
                //This ensures K is integral.
                checkSequenceIndex(index);
                static if(isIntegral!K)
                {
                    auto nodes = value_.get!(Node[]);
                    static if(is(Unqual!V == Node)){nodes[index] = value;}
                    else                           {nodes[index] = Node(value);}
                    value_ = Value(nodes);
                    return;
                }
                assert(false);
            }
            else if(isMapping())
            {
                const idx = findPair(index);
                if(idx < 0){add(index, value);}
                else
                {
                    auto pairs = as!(Node.Pair[])();
                    static if(is(Unqual!V == Node)){pairs[idx].value = value;}
                    else                           {pairs[idx].value = Node(value);}
                    value_ = Value(pairs);
                }
                return;
            }

            throw new Error("Trying to index a scalar node.", startMark_);
        }
        unittest
        {
            writeln("D:YAML Node opIndexAssign unittest");

            with(Node([1, 2, 3, 4, 3]))
            {
                opIndexAssign(42, 3);
                assert(length == 5);
                assert(opIndex(3).as!int == 42);
            }
            with(Node(["1", "2", "3"], [4, 5, 6]))
            {
                opIndexAssign(42, "3");
                opIndexAssign(123, 456);
                assert(length == 4);
                assert(opIndex("3").as!int == 42);
                assert(opIndex(456).as!int == 123);
            }
        }

        /**
         * Iterate over a sequence, getting each element as T.
         *
         * If T is Node, simply iterate over the nodes in the sequence.
         * Otherwise, convert each node to T during iteration.
         *
         * Throws:  NodeException if the node is not a sequence or an
         *          element could not be converted to specified type.
         */
        int opApply(T)(int delegate(ref T) dg)
        {
            enforce(isSequence, 
                    new Error("Trying to iterate over a node that is not a sequence",
                              startMark_));

            int result = 0;
            foreach(ref node; get!(Node[]))
            {
                static if(is(Unqual!T == Node))
                {
                    result = dg(node);
                }
                else
                {
                    T temp = node.as!T;
                    result = dg(temp);
                }
                if(result){break;}
            }
            return result;
        }
        unittest
        {
            writeln("D:YAML Node opApply unittest 1");

            alias Node.Value Value;
            alias Node.Pair Pair;

            Node n1 = Node(Value(cast(long)11));
            Node n2 = Node(Value(cast(long)12));
            Node n3 = Node(Value(cast(long)13));
            Node n4 = Node(Value(cast(long)14));
            Node narray = Node([n1, n2, n3, n4]);

            int[] array, array2;
            foreach(int value; narray)
            {
                array ~= value;
            }
            foreach(Node node; narray)
            {
                array2 ~= node.as!int;
            }
            assert(array == [11, 12, 13, 14]);
            assert(array2 == [11, 12, 13, 14]);
        }

        /**
         * Iterate over a mapping, getting each key/value as K/V.
         *
         * If the K and/or V is Node, simply iterate over the nodes in the mapping.
         * Otherwise, convert each key/value to T during iteration.
         *
         * Throws:  NodeException if the node is not a mapping or an
         *          element could not be converted to specified type.
         */
        int opApply(K, V)(int delegate(ref K, ref V) dg)
        {
            enforce(isMapping,
                    new Error("Trying to iterate over a node that is not a mapping",
                              startMark_));

            int result = 0;
            foreach(ref pair; get!(Node.Pair[]))
            {
                static if(is(Unqual!K == Node) && is(Unqual!V == Node))
                {
                    result = dg(pair.key, pair.value);
                }
                else static if(is(Unqual!K == Node))
                {
                    V tempValue = pair.value.as!V;
                    result = dg(pair.key, tempValue);
                }
                else static if(is(Unqual!V == Node))
                {
                    K tempKey   = pair.key.as!K;
                    result = dg(tempKey, pair.value);
                }
                else
                {
                    K tempKey   = pair.key.as!K;
                    V tempValue = pair.value.as!V;
                    result = dg(tempKey, tempValue);
                }
                    
                if(result){break;}
            }
            return result;
        }
        unittest
        {
            writeln("D:YAML Node opApply unittest 2");

            alias Node.Value Value;
            alias Node.Pair Pair;

            Node n1 = Node(cast(long)11);
            Node n2 = Node(cast(long)12);
            Node n3 = Node(cast(long)13);
            Node n4 = Node(cast(long)14);

            Node k1 = Node("11");
            Node k2 = Node("12");
            Node k3 = Node("13");
            Node k4 = Node("14");

            Node nmap1 = Node([Pair(k1, n1),
                               Pair(k2, n2),  
                               Pair(k3, n3),  
                               Pair(k4, n4)]);

            int[string] expected = ["11" : 11,
                                    "12" : 12,
                                    "13" : 13,
                                    "14" : 14];
            int[string] array;
            foreach(string key, int value; nmap1)
            {
                array[key] = value;
            }
            assert(array == expected);

            Node nmap2 = Node([Pair(k1, Node(cast(long)5)),
                               Pair(k2, Node(true)),  
                               Pair(k3, Node(cast(real)1.0)),  
                               Pair(k4, Node("yarly"))]);

            foreach(string key, Node value; nmap2)
            {
                switch(key)
                {
                    case "11": assert(value.as!int    == 5      ); break;
                    case "12": assert(value.as!bool   == true   ); break;
                    case "13": assert(value.as!float  == 1.0    ); break;
                    case "14": assert(value.as!string == "yarly"); break;
                    default:   assert(false);
                }
            }
        }

        /**
         * Add an element to a sequence.
         *
         * This method can only be called on sequence nodes.
         *
         * If value is a node, it is copied to the sequence directly. Otherwise
         * value is converted to a node and then stored in the sequence.
         *
         * $(P When emitting, all values in the sequence will be emitted. When 
         * using the !!set tag, the user needs to ensure that all elements in 
         * the sequence are unique, otherwise $(B invalid) YAML code will be 
         * emitted.)
         *
         * Params:  value = Value to _add to the sequence.
         */
        void add(T)(T value)
        {
            enforce(isSequence(), 
                    new Error("Trying to add an element to a non-sequence node", startMark_));

            auto nodes = get!(Node[])();
            static if(is(Unqual!T == Node)){nodes ~= value;}
            else                    {nodes ~= Node(value);}
            value_ = Value(nodes);
        }
        unittest
        {
            writeln("D:YAML Node add unittest 1");

            with(Node([1, 2, 3, 4]))
            {
                add(5.0f);
                assert(opIndex(4).as!float == 5.0f);
            }
        }

        /**
         * Add a key-value pair to a mapping.
         *
         * This method can only be called on mapping nodes.
         *
         * If key and/or value is a node, it is copied to the mapping directly. 
         * Otherwise it is converted to a node and then stored in the mapping.
         *
         * $(P It is possible for the same key to be present more than once in a
         * mapping. When emitting, all key-value pairs will be emitted. 
         * This is useful with the "!!pairs" tag, but will result in 
         * $(B invalid) YAML with "!!map" and "!!omap" tags.)
         *
         * Params:  key   = Key to _add.
         *          value = Value to _add.
         */
        void add(K, V)(K key, V value)
        {
            enforce(isMapping(), 
                    new Error("Trying to add a key-value pair to a non-mapping node", 
                              startMark_));

            auto pairs = get!(Node.Pair[])();
            pairs ~= Pair(key, value);
            value_ = Value(pairs);
        }
        unittest
        {
            writeln("D:YAML Node add unittest 2");
            with(Node([1, 2], [3, 4]))
            {
                add(5, "6");
                assert(opIndex(5).as!string == "6");
            }
        }

        /**
         * Remove first (if any) occurence of a value in a collection.
         *
         * This method can only be called on collection nodes.
         *
         * If the node is a sequence, the first node matching value (including
         * conversion, so e.g. "42" matches 42) is removed.
         * If the node is a mapping, the first key-value pair where _value 
         * matches specified value is removed.
         * 
         * Params:  value = Value to _remove.
         *
         * Throws:  NodeException if the node is not a collection.
         */
        void remove(T)(T value)
        {
            if(isSequence())
            {
                foreach(idx, ref elem; get!(Node[]))
                {
                    if(elem.convertsTo!T && elem.as!T == value)
                    {
                        removeAt(idx);
                        return;
                    }
                }
                return;
            }
            else if(isMapping())
            {
                const idx = findPair!(T, true)(value);
                if(idx >= 0)
                {
                    auto pairs = as!(Node.Pair[])();
                    moveAll(pairs[idx + 1 .. $], pairs[idx .. $ - 1]);
                    pairs.length = pairs.length - 1;
                    value_ = Value(pairs);
                }
                return;
            }
            throw new Error("Trying to remove an element from a scalar node", startMark_);
        }
        unittest
        {
            writeln("D:YAML Node remove unittest");
            with(Node([1, 2, 3, 4, 3]))
            {
                remove(3);
                assert(length == 4);
                assert(opIndex(2).as!int == 4);
                assert(opIndex(3).as!int == 3);
            }
            with(Node(["1", "2", "3"], [4, 5, 6]))
            {
                remove(4);
                assert(length == 2);
            }
        }

        /**
         * Remove element at the specified index of a collection.
         *
         * This method can only be called on collection nodes.
         * 
         * If the node is a sequence, index must be integral.
         *
         * If the node is a mapping, remove the first key-value pair where 
         * key matches index (including conversion, so e.g. "42" matches 42).
         * 
         * If the node is a mapping and no key matches index, nothing is removed
         * and no exception is thrown. This ensures behavior siilar to D arrays 
         * and associative arrays.
         *
         * Params:  index = Index to remove at.
         *
         * Throws:  NodeException if the node is not a collection, index is out
         *          of range or if a non-integral index is used on a sequence node.
         */
        void removeAt(T)(T index)
        {
            if(isSequence())
            {
                //This ensures T is integral.
                checkSequenceIndex(index);
                static if(isIntegral!T)
                {
                    auto nodes = value_.get!(Node[]);
                    moveAll(nodes[index + 1 .. $], nodes[index .. $ - 1]);
                    nodes.length = nodes.length - 1;
                    value_ = Value(nodes);
                    return;
                }
                assert(false);
            }
            else if(isMapping())
            {
                const idx = findPair(index);
                if(idx >= 0)
                {
                    auto pairs = get!(Node.Pair[])();
                    moveAll(pairs[idx + 1 .. $], pairs[idx .. $ - 1]);
                    pairs.length = pairs.length - 1;
                    value_ = Value(pairs);
                }
                return;
            }
            throw new Error("Trying to remove an element from a scalar node", startMark_);
        }
        unittest
        {
            writeln("D:YAML Node removeAt unittest");
            with(Node([1, 2, 3, 4, 3]))
            {
                removeAt(3);
                assert(length == 4);
                assert(opIndex(3).as!int == 3);
            }
            with(Node(["1", "2", "3"], [4, 5, 6]))
            {
                removeAt("2");
                assert(length == 2);
            }
        }

    package:
        /*
         * Construct a node from raw data.
         *
         * Params:  value           = Value of the node.
         *          startMark       = Start position of the node in file.
         *          tag             = Tag of the node.
         *          scalarStyle     = Scalar style of the node.
         *          collectionStyle = Collection style of the node.
         *
         * Returns: Constructed node.
         */
        static Node rawNode(Value value, in Mark startMark, in Tag tag, 
                            in ScalarStyle scalarStyle, 
                            in CollectionStyle collectionStyle)
        {
            Node node;
            node.value_ = value;
            node.startMark_ = startMark;
            node.tag_ = tag;
            node.scalarStyle = scalarStyle;
            node.collectionStyle = collectionStyle;

            return node;
        }

        //Construct Node.Value from user defined type.
        static Value userValue(T)(T value)
        {
            return Value(cast(YAMLObject)new YAMLContainer!T(value));
        }

        /*
         * Equality test with any value.
         *
         * useTag determines whether or not to consider tags in node-node comparisons.
         */
        bool equals(bool useTag, T)(ref T rhs) const
        {
            static if(is(Unqual!T == Node))
            {
                static if(useTag)
                {
                    if(tag_ != rhs.tag_){return false;}
                }

                if(!isValid){return !rhs.isValid;}
                if(!rhs.isValid || !hasEqualType(rhs))
                {
                    return false;
                }

                static bool compareCollection(T)(const ref Node lhs, const ref Node rhs)
                {
                    const c1 = lhs.value_.get!(const T);
                    const c2 = rhs.value_.get!(const T);
                    if(c1 is c2){return true;}
                    if(c1.length != c2.length){return false;}
                    foreach(i; 0 .. c1.length)
                    {
                        if(!c1[i].equals!useTag(c2[i])){return false;}
                    }
                    return true;
                }

                static bool compare(T)(const ref Node lhs, const ref Node rhs) 
                {
                    return lhs.value_.get!(const T) == rhs.value_.get!(const T);
                }

                if(isSequence)    {return compareCollection!(Node[])(this, rhs);}
                else if(isMapping){return compareCollection!(Pair[])(this, rhs);}
                else if(isString) {return compare!string(this, rhs);}
                else if(isInt)    {return compare!long(this, rhs);}
                else if(isBool)   {return compare!bool(this, rhs);}
                else if(isBinary) {return compare!(ubyte[])(this, rhs);}
                else if(isNull)   {return true;}
                else if(isFloat)
                {
                    const r1 = value_.get!(const real);
                    const r2 = rhs.value_.get!(const real);
                    return isNaN(r1) ? isNaN(r2) 
                                     : (r1 <= r2 + real.epsilon && r1 >= r2 - real.epsilon);
                }
                else if(isTime)
                {
                    const t1 = value_.get!(const SysTime);
                    const t2 = rhs.value_.get!(const SysTime);
                    return t1 == t2;
                }
                else if(isUserType)
                {
                    return value_.get!(const YAMLObject).equals(rhs.value_.get!(const YAMLObject));
                }
                assert(false, "Unknown kind of node (equality comparison) : " ~ type.toString);
            }
            else
            {
                try{return rhs == get!T;}
                catch(NodeException e){return false;}
            }
        }

        /*
         * Get a string representation of the node tree. Used for debugging.
         *
         * Params:  level = Level of the node in the tree.
         *
         * Returns: String representing the node tree.
         */
        @property string debugString(uint level = 0)
        {
            string indent;
            foreach(i; 0 .. level){indent ~= " ";}

            if(!isValid){return indent ~ "invalid";}

            if(isSequence)
            {
                string result = indent ~ "sequence:\n";
                foreach(ref node; get!(Node[]))
                {
                    result ~= node.debugString(level + 1);
                }
                return result;
            }
            if(isMapping)
            {
                string result = indent ~ "mapping:\n";
                foreach(ref pair; get!(Node.Pair[]))
                {
                    result ~= indent ~ " pair\n";
                    result ~= pair.key.debugString(level + 2);
                    result ~= pair.value.debugString(level + 2);
                }
                return result;
            }
            if(isScalar)
            {
                return indent ~ "scalar(" ~ 
                       (convertsTo!string ? get!string : type.toString) ~ ")\n";
            }
            assert(false);
        }

        //Get type of the node value (YAMLObject for user types).
        @property TypeInfo type() const {return value_.type;}

        /*
         * Determine if the value stored by the node is of specified type.
         *
         * This only works for default YAML types, not for user defined types.
         */
        @property bool isType(T)() const {return value_.type is typeid(Unqual!T);}

    private:
        //Is the value a bool?
        alias isType!bool isBool;

        //Is the value a raw binary buffer?
        alias isType!(ubyte[]) isBinary;

        //Is the value an integer?
        alias isType!long isInt;

        //Is the value a floating point number?
        alias isType!real isFloat;

        //Is the value a string?
        alias isType!string isString;

        //Is the value a timestamp?
        alias isType!SysTime isTime;

        //Is the value a null value?
        alias isType!YAMLNull isNull;

        //Does given node have the same type as this node?
        bool hasEqualType(const ref Node node) const
        {                 
            return value_.type is node.value_.type;
        }

        //Determine if the value can be converted to specified type.
        bool convertsTo(T)() const
        {
            if(isType!T){return true;}

            //Every type allowed in Value should be convertible to string.
            static if(isSomeString!T)        {return true;}
            else static if(isFloatingPoint!T){return isInt() || isFloat();}
            else static if(isIntegral!T)     {return isInt();}
            else                             {return false;}
        }

        //Get index of pair with key (or value, if value is true) matching index.
        long findPair(T, bool value = false)(const ref T index) const
        {
            const pairs = value_.get!(const Pair[])();
            const(Node)* node;
            foreach(idx, ref const(Pair) pair; pairs)
            {
                static if(value){node = &pair.value;}
                else{node = &pair.key;}

                static if(is(Unqual!T == Node))
                {
                    if(*node == index){return idx;}
                }
                else static if(isFloatingPoint!T)
                {
                    //Need to handle NaNs separately.
                    if((node.as!T == index) ||
                       (isFloat && isNaN(index) && isNaN(node.as!real)))
                    {
                        return idx;
                    }
                }
                else 
                {  
                    try if(node.as!(const T) == index){return idx;}
                    catch(NodeException e)
                    {
                        continue;
                    }
                }
            }
            return -1;
        }

        //Check if index is integral and in range.
        void checkSequenceIndex(T)(T index) const
        {
            static if(!isIntegral!T)
            {
                throw new Error("Indexing a sequence with a non-integral type.", startMark_);
            }
            else
            {
                enforce(index >= 0 && index < value_.get!(const Node[]).length,
                        new Error("Sequence index out of range: " ~ to!string(index), 
                                  startMark_));
            }
        }

        //Const version of opIndex.
        ref const(Node) indexConst(T)(T index) const
        {
            if(isSequence)
            {
                checkSequenceIndex(index);
                static if(isIntegral!T)
                {
                    return value_.get!(const Node[])[index];
                }
                assert(false);
            }
            else if(isMapping)
            {
                auto idx = findPair(index);
                if(idx >= 0)
                {
                    return value_.get!(const Pair[])[idx].value;
                }

                string msg = "Mapping index not found" ~ (isSomeString!T ? ": " ~ to!string(index) : "");
                throw new Error(msg, startMark_);
            }
            throw new Error("Trying to index node that does not support indexing", startMark_);
        }
}

package:
/*
 * Merge a pair into an array of pairs based on merge rules in the YAML spec.
 *
 * The new pair will only be added if there is not already a pair 
 * with the same key.
 *
 * Params:  pairs   = Array of pairs to merge into.
 *          toMerge = Pair to merge.
 */ 
void merge(ref Node.Pair[] pairs, ref Node.Pair toMerge)
{
    foreach(ref pair; pairs)
    {
        if(pair.key == toMerge.key){return;}
    }
    pairs ~= toMerge;
}

/*
 * Merge pairs into an array of pairs based on merge rules in the YAML spec.
 *
 * Any new pair will only be added if there is not already a pair 
 * with the same key.
 *
 * Params:  pairs   = Array of pairs to merge into.
 *          toMerge = Pairs to merge.
 */
void merge(ref Node.Pair[] pairs, Node.Pair[] toMerge)
{
    bool eq(ref Node.Pair a, ref Node.Pair b){return a.key == b.key;}

    //Preallocating to limit GC reallocations.
    auto len = pairs.length;
    pairs.length = len + toMerge.length;
    foreach(ref pair; toMerge) if(!canFind!eq(pairs, pair))
    {
        pairs[len++] = pair;
    }
    pairs.length = len;
}
