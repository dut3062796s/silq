// Written in the D programming language
// License: http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0

import std.array, std.algorithm, std.conv;
import std.functional;
import expression, declaration, util;

bool compatible(Expression lhs,Expression rhs){
	return lhs.eval() == rhs.eval();
}


class Type: Expression{
	this(){ if(!this.type) this.type=typeTy; sstate=SemState.completed; }
	override @property string kind(){ return "type"; }
	override string toString(){ return "T"; }
	abstract override bool opEquals(Object r);
}

class ErrorTy: Type{
	this(){}//{sstate = SemState.error;}
	override string toString(){return "__error";}
	mixin VariableFree;
}


class ℝTy: Type{
	private this(){}
	override string toString(){
		return "ℝ";
	}
	override bool opEquals(Object o){
		return !!cast(ℝTy)o;
	}
	mixin VariableFree;
}
private ℝTy theℝ;

ℝTy ℝ(){ return theℝ?theℝ:(theℝ=new ℝTy()); }

class AggregateTy: Type{
	DatDecl decl;
	this(DatDecl decl){
		this.decl=decl;
	}
	override bool opEquals(Object o){
		if(auto r=cast(AggregateTy)o)
			return decl is r.decl;
		return false;
	}
	mixin VariableFree;
}

class ContextTy: Type{
	private this(){} // dummy
	override bool opEquals(Object o){
		return !!cast(ContextTy)o;
	}
	mixin VariableFree;
}
private ContextTy theContextTy;
ContextTy contextTy(){ return theContextTy?theContextTy:(theContextTy=new ContextTy()); }



class TupleTy: Type{
	Expression[] types;
	private this(Expression[] types)in{
		assert(types.all!(x=>x.type==typeTy));
	}body{
		this.types=types;
	}
	override string toString(){
		if(!types.length) return "𝟙";
		if(types.length==1) return "("~types[0].toString()~")¹";
		string addp(Expression a){
			if(cast(FunTy)a) return "("~a.toString()~")";
			return a.toString();
		}
		return types.map!(a=>cast(TupleTy)a&&a!is unit?"("~a.toString()~")":addp(a)).join(" × ");
	}
	override int freeVarsImpl(scope int delegate(string) dg){
		foreach(t;types)
			if(auto r=t.freeVarsImpl(dg))
				return r;
		return 0;
	}
	override TupleTy substitute(Expression[string] subst){
		auto ntypes=types.dup;
		foreach(ref t;ntypes) t=t.substitute(subst);
		return tupleTy(ntypes);
	}
	override bool opEquals(Object o){
		if(auto r=cast(TupleTy)o)
			return types==r.types;
		return false;
	}
}

TupleTy unit(){ return tupleTy([]); }

TupleTy tupleTy(Expression[] types)in{
	assert(types.all!(x=>x.type==typeTy));
}body{
	return memoize!((Expression[] types)=>new TupleTy(types))(types);
}

class ArrayTy: Type{
	Expression next;
	private this(Expression next)in{
		assert(next.type==typeTy);
	}body{
		this.next=next;
	}
	override string toString(){
		bool p=cast(FunTy)next||cast(TupleTy)next&&next!is unit;
		return p?"("~next.toString()~")[]":next.toString()~"[]";
	}
	override int freeVarsImpl(scope int delegate(string) dg){
		return next.freeVarsImpl(dg);
	}
	override ArrayTy substitute(Expression[string] subst){
		return arrayTy(next.substitute(subst));
	}
	override ArrayTy eval(){
		return arrayTy(next.eval());
	}
	override bool opEquals(Object o){
		if(auto r=cast(ArrayTy)o)
			return next==r.next;
		return false;
	}
}

ArrayTy arrayTy(Expression next)in{
	assert(next.type==typeTy);
}body{
	return memoize!((Expression next)=>new ArrayTy(next))(next);
}

class StringTy: Type{
	private this(){}
	override string toString(){
		return "string";
	}
	override bool opEquals(Object o){
		return !!cast(StringTy)o;
	}
	mixin VariableFree;
}

StringTy stringTy(){ return memoize!(()=>new StringTy()); }

class ForallTy: Type{
	string[] names;
	TupleTy dom;
	Expression cod;
	private this(string[] names,TupleTy dom,Expression cod)in{
		assert(names.length==dom.types.length);
		assert(cod.type==typeTy);
	}body{
		this.names=names; this.dom=dom; this.cod=cod;
	}
	override string toString(){
		auto d=dom.types.length==1?dom.types[0].toString():dom.toString(), c=cod.toString();
		if(dom&&dom.types.length>1||cast(FunTy)dom.types[0]) d="("~d~")";
		if(cast(TupleTy)cod) c="("~c~")";
		if(!cod.hasAnyFreeVar(names)){
			return d~" → "~c;
		}else{
			assert(names.length);
			return "∀"~(names.length==1?names[0]:"("~names.join(",")~")")~": "~d~". "~c;
		}
	}
	@property size_t nargs(){
		if(auto tplargs=cast(TupleTy)dom) return tplargs.types.length;
		return 1;
	}
	Expression argTy(size_t i)in{assert(i<nargs);}body{
		return dom.types[i];
	}
	override int freeVarsImpl(scope int delegate(string) dg){
		if(auto r=dom.freeVarsImpl(dg)) return r;
		return cod.freeVarsImpl(v=>names.canFind(v)?0:dg(v));
	}
	private ForallTy relabel(string oname,string nname)in{assert(names.canFind(oname));}body{
		auto nnames=names.dup;
		foreach(ref v;nnames) if(v==oname) v=nname; // TODO: this is rather dumb
		auto nvar=varTy(nname);
		return forallTy(nnames,dom,cod.substitute(oname,nvar));
	}
	override ForallTy substitute(Expression[string] subst){
		foreach(n;names){
			bool ok=true;
			foreach(k,v;subst) if(v.hasFreeVar(n)) ok=false;
			if(ok) continue;
			return relabel(n,n~"'").substitute(subst);
		}
		auto ndom=dom.substitute(subst);
		auto nsubst=subst.dup;
		foreach(n;names) nsubst.remove(n);
		auto ncod=cod.substitute(nsubst);
		return forallTy(names,ndom,ncod);
	}
	Expression tryApply(Expression[] rhs){
		if(rhs.length!=names.length) return null;
		foreach(i,r;rhs){
			if(!compatible(dom.types[i],rhs[i].type))
				return null;
		}
		Expression r=cod;
		foreach(i,n;names)
			r=r.substitute(n,rhs[i]); // TODO: avoid capturing!
		return r;
	}
	override bool opEquals(Object o){
		auto r=cast(ForallTy)o;
		if(!r) return false;
		if(dom.types.length!=r.dom.types.length) return false;
		foreach(i;0..dom.types.length)
			r=r.relabel(r.names[i],names[i]);
		return dom==r.dom&&cod==r.cod;
	}
}

ForallTy forallTy(string[] names,TupleTy dom,Expression cod){
	return memoize!((string[] names,TupleTy dom,Expression cod)=>new FunTy(names,dom,cod))(names,dom,cod);
}

alias FunTy=ForallTy;
FunTy funTy(TupleTy dom,Expression cod){
	return forallTy(dom.types.map!(_=>"").array,dom,cod);
}

/+FunTy funTy(TupleTy dom,Type cod){
	return memoize!((string[] names,TupleTy dom,Type cod)=>new FunTy(names,dom,cod))(names,dom,cod);
}+/


class VarTy: Type{
	string name;
	private this(string name){ this.name=name; }
	override string toString(){
		return name;
	}
	override int freeVarsImpl(scope int delegate(string) dg){
		return dg(name);
	}
	override Expression substitute(Expression[string] subst){
		if(name in subst) return subst[name];
		return this;
	}
	override bool opEquals(Object o){
		if(auto r=cast(VarTy)o)
			return name==r.name;
		return false;
	}
}

VarTy varTy(string name){
	return memoize!((string name)=>new VarTy(name))(name);
}

class TypeTy: Type{
	this(){ this.type=this; super(); }
	override string toString(){
		return "*";
	}
	override bool opEquals(Object o){
		return !!cast(TypeTy)o;
	}
	mixin VariableFree;
}
private TypeTy theTypeTy;
TypeTy typeTy(){ return theTypeTy?theTypeTy:(theTypeTy=new TypeTy()); }
