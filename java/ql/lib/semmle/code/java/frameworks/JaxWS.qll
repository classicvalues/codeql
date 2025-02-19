/**
 * Definitions relating to JAX-WS (Java/Jakarta API for XML Web Services) and JAX-RS
 * (Java/Jakarta API for RESTful Web Services).
 */

import java
private import semmle.code.java.dataflow.ExternalFlow
private import semmle.code.java.security.XSS

/**
 * Gets a name for the root package of JAX-RS.
 */
string getAJaxRsPackage() { result in ["javax.ws.rs", "jakarta.ws.rs"] }

/**
 * Gets a name for package `subpackage` within the JAX-RS hierarchy.
 */
bindingset[subpackage]
string getAJaxRsPackage(string subpackage) { result = getAJaxRsPackage() + "." + subpackage }

/**
 * A JAX WS endpoint is constructed by the container, and its methods
 * are -- where annotated -- called remotely.
 */
class JaxWsEndpoint extends Class {
  JaxWsEndpoint() {
    exists(AnnotationType a | a = this.getAnAnnotation().getType() |
      a.hasName("WebService") or
      a.hasName("WebServiceProvider") or
      a.hasName("WebServiceClient")
    )
  }

  /** Gets a method annotated with `@WebMethod` or `@WebEndpoint`. */
  Callable getARemoteMethod() {
    result = this.getACallable() and
    exists(AnnotationType a | a = result.getAnAnnotation().getType() |
      a.hasName("WebMethod") or
      a.hasName("WebEndpoint")
    )
  }
}

/**
 * Holds if the annotatable has the JaxRs `@Path` annotation.
 */
private predicate hasPathAnnotation(Annotatable annotatable) {
  exists(AnnotationType a |
    a = annotatable.getAnAnnotation().getType() and
    a.getPackage().getName() = getAJaxRsPackage()
  |
    a.hasName("Path")
  )
}

/**
 * A method which is annotated with one or more JaxRS resource type annotations e.g. `@GET`, `@POST` etc.
 */
class JaxRsResourceMethod extends Method {
  JaxRsResourceMethod() {
    exists(AnnotationType a |
      a = this.getAnAnnotation().getType() and
      a.getPackage().getName() = getAJaxRsPackage()
    |
      a.hasName("GET") or
      a.hasName("POST") or
      a.hasName("DELETE") or
      a.hasName("PUT") or
      a.hasName("OPTIONS") or
      a.hasName("HEAD")
    )
    or
    // A JaxRS resource method can also inherit these annotations from a supertype, but only if
    // there are no JaxRS annotations on the method itself
    this.getAnOverride() instanceof JaxRsResourceMethod and
    not exists(this.getAnAnnotation().(JaxRSAnnotation))
  }

  /** Gets an `@Produces` annotation that applies to this method */
  JaxRSProducesAnnotation getProducesAnnotation() {
    result = this.getAnAnnotation()
    or
    // No direct annotations
    not this.getAnAnnotation() instanceof JaxRSProducesAnnotation and
    (
      // Annotations on a method we've overridden
      result = this.getAnOverride().getAnAnnotation()
      or
      // No annotations on this method, or a method we've overridden, so look to the class
      not this.getAnOverride().getAnAnnotation() instanceof JaxRSProducesAnnotation and
      result = this.getDeclaringType().getAnAnnotation()
    )
  }
}

/**
 * A JaxRs resource class, annotated with `@Path` or referred to from a sub-resource locator on
 * another resource class.
 *
 * This class contains resource methods, which are executed in response to requests.
 */
class JaxRsResourceClass extends Class {
  JaxRsResourceClass() {
    // A root resource class has a @Path annotation on the class.
    hasPathAnnotation(this)
    or
    // A sub-resource
    exists(JaxRsResourceClass resourceClass, Method method |
      // This is a sub-resource class is if it is referred to from the sub-resource locator of
      // another resource class.
      method = resourceClass.getASubResourceLocator()
    |
      this = method.getReturnType()
    )
  }

  /**
   * Gets a resource method on this resource class.
   *
   * Resource methods may be executed in response to web requests which match the `@Path`
   * annotations leading to this resource method.
   */
  JaxRsResourceMethod getAResourceMethod() {
    this.isPublic() and
    result = this.getACallable()
  }

  /**
   * Gets a "sub-resource locator" on this resource class, which is a method annotated with `@Path`,
   * but is not a resource method e.g. it is not annotated with `@GET` etc.
   */
  Callable getASubResourceLocator() {
    result = this.getAMethod() and
    not result instanceof JaxRsResourceMethod and
    hasPathAnnotation(result)
  }

  /**
   * Holds if this class is a "root resource" class
   */
  predicate isRootResource() { hasPathAnnotation(this) }

  /**
   * Gets a `Constructor` that may be called by a JaxRS container to construct this class reflectively.
   *
   * This only considers which constructors adhere to the rules for injectable constructors. In the
   * case of multiple matching constructors, the container will choose the constructor with the most
   * matching parameters, but this is not modeled, because it may take into account runtime aspects
   * (existence of particular parameters).
   */
  Constructor getAnInjectableConstructor() {
    result = this.getAConstructor() and
    // JaxRs Spec v2.0 - 3.12
    // Only root resources are constructed by the JaxRS container.
    this.isRootResource() and
    // JaxRS can only construct the class using constructors that are public, and where the
    // container can provide all of the parameters. This includes the no-arg constructor.
    result.isPublic() and
    forall(Parameter p | p = result.getAParameter() |
      p.getAnAnnotation() instanceof JaxRsInjectionAnnotation
    )
  }

  /**
   * Gets a Callable that may be executed by the JaxRs container, injecting parameters as required.
   */
  Callable getAnInjectableCallable() {
    result = this.getAResourceMethod() or
    result = this.getAnInjectableConstructor() or
    result = this.getASubResourceLocator()
  }

  /**
   * Gets a Field that may be injected with a value by the JaxRs container.
   */
  Field getAnInjectableField() {
    result = this.getAField() and
    result.getAnAnnotation() instanceof JaxRsInjectionAnnotation
  }
}

/**
 * An annotation from the `javax.ws.rs` or `jakarta.ws.rs` package hierarchy.
 */
class JaxRSAnnotation extends Annotation {
  JaxRSAnnotation() {
    exists(AnnotationType a |
      a = this.getType() and
      a.getPackage().getName().regexpMatch(["javax\\.ws\\.rs(\\..*)?", "jakarta\\.ws\\.rs(\\..*)?"])
    )
  }
}

/**
 * An annotation that is used by JaxRS containers to determine a value to inject into the annotated
 * element.
 */
class JaxRsInjectionAnnotation extends JaxRSAnnotation {
  JaxRsInjectionAnnotation() {
    exists(AnnotationType a |
      a = this.getType() and
      a.getPackage().getName() = getAJaxRsPackage()
    |
      a.hasName("BeanParam") or
      a.hasName("CookieParam") or
      a.hasName("FormParam") or
      a.hasName("HeaderParam") or
      a.hasName("MatrixParam") or
      a.hasName("PathParam") or
      a.hasName("QueryParam")
    )
    or
    this.getType().hasQualifiedName(getAJaxRsPackage("core"), "Context")
  }
}

/**
 * The class `javax.ws.rs.core.Response`.
 */
class JaxRsResponse extends Class {
  JaxRsResponse() { this.hasQualifiedName(getAJaxRsPackage("core"), "Response") }
}

/**
 * The class `javax.ws.rs.core.Response$ResponseBuilder`.
 */
class JaxRsResponseBuilder extends Class {
  JaxRsResponseBuilder() {
    this.hasQualifiedName(getAJaxRsPackage("core"), "Response$ResponseBuilder")
  }
}

/**
 * The class `javax.ws.rs.client.Client`.
 */
class JaxRsClient extends RefType {
  JaxRsClient() { this.hasQualifiedName(getAJaxRsPackage("client"), "Client") }
}

/**
 * A constructor that may be called by a JaxRS container to construct an instance to inject into a
 * resource method or resource class constructor.
 */
class JaxRsBeanParamConstructor extends Constructor {
  JaxRsBeanParamConstructor() {
    exists(JaxRsResourceClass resourceClass, Callable c, Parameter p |
      c = resourceClass.getAnInjectableCallable() and
      p = c.getAParameter() and
      p.getAnAnnotation().getType().hasQualifiedName(getAJaxRsPackage(), "BeanParam") and
      this.getDeclaringType().getSourceDeclaration() = p.getType().(RefType).getSourceDeclaration()
    ) and
    forall(Parameter p | p = this.getAParameter() |
      p.getAnAnnotation() instanceof JaxRsInjectionAnnotation
    )
  }
}

/**
 * The class `javax.ws.rs.ext.MessageBodyReader`.
 */
class MessageBodyReader extends GenericInterface {
  MessageBodyReader() { this.hasQualifiedName(getAJaxRsPackage("ext"), "MessageBodyReader") }
}

/**
 * The method `readFrom` in `MessageBodyReader`.
 */
class MessageBodyReaderReadFrom extends Method {
  MessageBodyReaderReadFrom() {
    this.getDeclaringType().getSourceDeclaration() instanceof MessageBodyReader and
    this.hasName("readFrom")
  }
}

/**
 * A method that overrides `readFrom` in `MessageBodyReader`.
 */
class MessageBodyReaderRead extends Method {
  MessageBodyReaderRead() {
    exists(Method m | m.getSourceDeclaration() instanceof MessageBodyReaderReadFrom |
      this.overrides*(m)
    )
  }
}

/**
 * Gets a constant content-type described by expression `e` (either a string constant or a Jax-RS MediaType field access).
 */
string getContentTypeString(Expr e) {
  result = e.(CompileTimeConstantExpr).getStringValue() and
  result != ""
  or
  exists(Field jaxMediaType |
    // Accesses to static fields on `MediaType` class do not have constant strings in the database
    // so convert the field name to a content type string
    jaxMediaType.getDeclaringType().hasQualifiedName(getAJaxRsPackage("core"), "MediaType") and
    jaxMediaType.getAnAccess() = e and
    // e.g. MediaType.TEXT_PLAIN => text/plain
    result = jaxMediaType.getName().toLowerCase().replaceAll("_value", "").replaceAll("_", "/")
  )
}

/** An `@Produces` annotation that describes which content types can be produced by this resource. */
class JaxRSProducesAnnotation extends JaxRSAnnotation {
  JaxRSProducesAnnotation() { this.getType().hasQualifiedName(getAJaxRsPackage(), "Produces") }

  /**
   * Gets a declared content type that can be produced by this resource.
   */
  Expr getADeclaredContentTypeExpr() {
    result = this.getAValue() and not result instanceof ArrayInit
    or
    result = this.getAValue().(ArrayInit).getAnInit()
  }
}

/** An `@Consumes` annotation that describes content types can be consumed by this resource. */
class JaxRSConsumesAnnotation extends JaxRSAnnotation {
  JaxRSConsumesAnnotation() { this.getType().hasQualifiedName(getAJaxRsPackage(), "Consumes") }
}

/** A default sink representing methods susceptible to XSS attacks. */
private class JaxRSXssSink extends XssSink {
  JaxRSXssSink() {
    exists(JaxRsResourceMethod resourceMethod, ReturnStmt rs |
      resourceMethod = any(JaxRsResourceClass resourceClass).getAResourceMethod() and
      rs.getEnclosingCallable() = resourceMethod and
      this.asExpr() = rs.getResult()
    |
      not exists(resourceMethod.getProducesAnnotation())
      or
      isXssVulnerableContentType(getContentTypeString(resourceMethod
              .getProducesAnnotation()
              .getADeclaredContentTypeExpr()))
    )
  }
}

/** A URL redirection sink from JAX-RS */
private class JaxRsUrlRedirectSink extends SinkModelCsv {
  override predicate row(string row) {
    row =
      [
        //`namespace; type; subtypes; name; signature; ext; input; kind`
        "javax.ws.rs.core;Response;true;seeOther;;;Argument[0];url-redirect",
        "javax.ws.rs.core;Response;true;temporaryRedirect;;;Argument[0];url-redirect",
        "jakarta.ws.rs.core;Response;true;seeOther;;;Argument[0];url-redirect",
        "jakarta.ws.rs.core;Response;true;temporaryRedirect;;;Argument[0];url-redirect"
      ]
  }
}

/**
 * Model Response:
 *
 * - the returned ResponseBuilder gains taint from a tainted entity or existing Response
 */
private class ResponseModel extends SummaryModelCsv {
  override predicate row(string row) {
    row =
      [
        "javax.ws.rs.core;Response;false;accepted;;;Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;Response;false;fromResponse;;;Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;Response;false;ok;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;Response;false;accepted;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;Response;false;fromResponse;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;Response;false;ok;;;Argument[0];ReturnValue;taint"
      ]
  }
}

/**
 * Model ResponseBuilder:
 *
 * - becomes tainted by a tainted entity, but not by metadata, headers etc
 * - build() method returns taint
 * - almost all methods are fluent, and so preserve value
 */
private class ResponseBuilderModel extends SummaryModelCsv {
  override predicate row(string row) {
    row =
      [
        "javax.ws.rs.core;Response$ResponseBuilder;true;build;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;Response$ResponseBuilder;true;entity;;;Argument[0];Argument[-1];taint",
        "javax.ws.rs.core;Response$ResponseBuilder;true;allow;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;Response$ResponseBuilder;true;cacheControl;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;Response$ResponseBuilder;true;clone;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;Response$ResponseBuilder;true;contentLocation;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;Response$ResponseBuilder;true;cookie;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;Response$ResponseBuilder;true;encoding;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;Response$ResponseBuilder;true;entity;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;Response$ResponseBuilder;true;expires;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;Response$ResponseBuilder;true;header;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;Response$ResponseBuilder;true;language;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;Response$ResponseBuilder;true;lastModified;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;Response$ResponseBuilder;true;link;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;Response$ResponseBuilder;true;links;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;Response$ResponseBuilder;true;location;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;Response$ResponseBuilder;true;replaceAll;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;Response$ResponseBuilder;true;status;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;Response$ResponseBuilder;true;tag;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;Response$ResponseBuilder;true;type;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;Response$ResponseBuilder;true;variant;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;Response$ResponseBuilder;true;variants;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;build;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;entity;;;Argument[0];Argument[-1];taint",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;allow;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;cacheControl;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;clone;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;contentLocation;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;cookie;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;encoding;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;entity;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;expires;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;header;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;language;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;lastModified;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;link;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;links;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;location;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;replaceAll;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;status;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;tag;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;type;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;variant;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Response$ResponseBuilder;true;variants;;;Argument[-1];ReturnValue;value"
      ]
  }
}

/**
 * Model HttpHeaders: methods that Date have to be syntax-checked, but those returning MediaType
 * or Locale are assumed potentially dangerous, as these types do not generally check that the
 * input data is recognised, only that it conforms to the expected syntax.
 */
private class HttpHeadersModel extends SummaryModelCsv {
  override predicate row(string row) {
    row =
      [
        "javax.ws.rs.core;HttpHeaders;true;getAcceptableLanguages;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;HttpHeaders;true;getAcceptableMediaTypes;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;HttpHeaders;true;getCookies;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;HttpHeaders;true;getHeaderString;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;HttpHeaders;true;getLanguage;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;HttpHeaders;true;getMediaType;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;HttpHeaders;true;getRequestHeader;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;HttpHeaders;true;getRequestHeaders;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;HttpHeaders;true;getAcceptableLanguages;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;HttpHeaders;true;getAcceptableMediaTypes;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;HttpHeaders;true;getCookies;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;HttpHeaders;true;getHeaderString;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;HttpHeaders;true;getLanguage;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;HttpHeaders;true;getMediaType;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;HttpHeaders;true;getRequestHeader;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;HttpHeaders;true;getRequestHeaders;;;Argument[-1];ReturnValue;taint"
      ]
  }
}

/**
 * Model MultivaluedMap, which extends Map<K, List<V>> and provides a few extra helper methods.
 */
private class MultivaluedMapModel extends SummaryModelCsv {
  override predicate row(string row) {
    row =
      [
        "javax.ws.rs.core;MultivaluedMap;true;add;;;Argument[0];MapKey of Argument[-1];value",
        "javax.ws.rs.core;MultivaluedMap;true;add;;;Argument[1];Element of MapValue of Argument[-1];value",
        "javax.ws.rs.core;MultivaluedMap;true;addAll;;;Argument[0];MapKey of Argument[-1];value",
        "javax.ws.rs.core;MultivaluedMap;true;addAll;(Object,List);;Element of Argument[1];Element of MapValue of Argument[-1];value",
        "javax.ws.rs.core;MultivaluedMap;true;addAll;(Object,Object[]);;ArrayElement of Argument[1];Element of MapValue of Argument[-1];value",
        "javax.ws.rs.core;MultivaluedMap;true;addFirst;;;Argument[0];MapKey of Argument[-1];value",
        "javax.ws.rs.core;MultivaluedMap;true;addFirst;;;Argument[1];Element of MapValue of Argument[-1];value",
        "javax.ws.rs.core;MultivaluedMap;true;getFirst;;;Element of MapValue of Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;MultivaluedMap;true;putSingle;;;Argument[0];MapKey of Argument[-1];value",
        "javax.ws.rs.core;MultivaluedMap;true;putSingle;;;Argument[1];Element of MapValue of Argument[-1];value",
        "jakarta.ws.rs.core;MultivaluedMap;true;add;;;Argument[0];MapKey of Argument[-1];value",
        "jakarta.ws.rs.core;MultivaluedMap;true;add;;;Argument[1];Element of MapValue of Argument[-1];value",
        "jakarta.ws.rs.core;MultivaluedMap;true;addAll;;;Argument[0];MapKey of Argument[-1];value",
        "jakarta.ws.rs.core;MultivaluedMap;true;addAll;(Object,List);;Element of Argument[1];Element of MapValue of Argument[-1];value",
        "jakarta.ws.rs.core;MultivaluedMap;true;addAll;(Object,Object[]);;ArrayElement of Argument[1];Element of MapValue of Argument[-1];value",
        "jakarta.ws.rs.core;MultivaluedMap;true;addFirst;;;Argument[0];MapKey of Argument[-1];value",
        "jakarta.ws.rs.core;MultivaluedMap;true;addFirst;;;Argument[1];Element of MapValue of Argument[-1];value",
        "jakarta.ws.rs.core;MultivaluedMap;true;getFirst;;;Element of MapValue of Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;MultivaluedMap;true;putSingle;;;Argument[0];MapKey of Argument[-1];value",
        "jakarta.ws.rs.core;MultivaluedMap;true;putSingle;;;Argument[1];Element of MapValue of Argument[-1];value"
      ]
  }
}

/**
 * Model AbstractMultivaluedMap, which implements MultivaluedMap.
 */
private class AbstractMultivaluedMapModel extends SummaryModelCsv {
  override predicate row(string row) {
    row =
      [
        "javax.ws.rs.core;AbstractMultivaluedMap;false;AbstractMultivaluedMap;;;MapKey of Argument[0];MapKey of Argument[-1];value",
        "javax.ws.rs.core;AbstractMultivaluedMap;false;AbstractMultivaluedMap;;;MapValue of Argument[0];MapValue of Argument[-1];value",
        "jakarta.ws.rs.core;AbstractMultivaluedMap;false;AbstractMultivaluedMap;;;MapKey of Argument[0];MapKey of Argument[-1];value",
        "jakarta.ws.rs.core;AbstractMultivaluedMap;false;AbstractMultivaluedMap;;;MapValue of Argument[0];MapValue of Argument[-1];value"
      ]
  }
}

/**
 * Model MultivaluedHashMap, which extends AbstractMultivaluedMap.
 */
private class MultivaluedHashMapModel extends SummaryModelCsv {
  override predicate row(string row) {
    row =
      [
        "javax.ws.rs.core;MultivaluedHashMap;false;MultivaluedHashMap;(Map);;MapKey of Argument[0];MapKey of Argument[-1];value",
        "javax.ws.rs.core;MultivaluedHashMap;false;MultivaluedHashMap;(Map);;MapValue of Argument[0];Element of MapValue of Argument[-1];value",
        "javax.ws.rs.core;MultivaluedHashMap;false;MultivaluedHashMap;(MultivaluedMap);;MapKey of Argument[0];MapKey of Argument[-1];value",
        "javax.ws.rs.core;MultivaluedHashMap;false;MultivaluedHashMap;(MultivaluedMap);;MapValue of Argument[0];MapValue of Argument[-1];value",
        "jakarta.ws.rs.core;MultivaluedHashMap;false;MultivaluedHashMap;(Map);;MapKey of Argument[0];MapKey of Argument[-1];value",
        "jakarta.ws.rs.core;MultivaluedHashMap;false;MultivaluedHashMap;(Map);;MapValue of Argument[0];Element of MapValue of Argument[-1];value",
        "jakarta.ws.rs.core;MultivaluedHashMap;false;MultivaluedHashMap;(MultivaluedMap);;MapKey of Argument[0];MapKey of Argument[-1];value",
        "jakarta.ws.rs.core;MultivaluedHashMap;false;MultivaluedHashMap;(MultivaluedMap);;MapValue of Argument[0];MapValue of Argument[-1];value"
      ]
  }
}

/**
 * Model PathSegment, which wraps a path and its associated matrix parameters.
 */
private class PathSegmentModel extends SummaryModelCsv {
  override predicate row(string row) {
    row =
      [
        "javax.ws.rs.core;PathSegment;true;getMatrixParameters;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;PathSegment;true;getPath;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;PathSegment;true;getMatrixParameters;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;PathSegment;true;getPath;;;Argument[-1];ReturnValue;taint"
      ]
  }
}

/**
 * Model UriInfo, which provides URI element accessors.
 */
private class UriInfoModel extends SummaryModelCsv {
  override predicate row(string row) {
    row =
      [
        "javax.ws.rs.core;UriInfo;true;getPathParameters;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;UriInfo;true;getPathSegments;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;UriInfo;true;getQueryParameters;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;UriInfo;true;getRequestUri;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;UriInfo;true;getRequestUriBuilder;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;UriInfo;true;getPathParameters;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;UriInfo;true;getPathSegments;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;UriInfo;true;getQueryParameters;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;UriInfo;true;getRequestUri;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;UriInfo;true;getRequestUriBuilder;;;Argument[-1];ReturnValue;taint"
      ]
  }
}

/**
 * Model Cookie, a simple tuple type.
 */
private class CookieModel extends SummaryModelCsv {
  override predicate row(string row) {
    row =
      [
        "javax.ws.rs.core;Cookie;true;getDomain;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;Cookie;true;getName;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;Cookie;true;getPath;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;Cookie;true;getValue;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;Cookie;true;getVersion;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;Cookie;true;toString;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;Cookie;false;Cookie;;;Argument[0..4];Argument[-1];taint",
        "javax.ws.rs.core;Cookie;false;valueOf;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;Cookie;true;getDomain;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;Cookie;true;getName;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;Cookie;true;getPath;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;Cookie;true;getValue;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;Cookie;true;getVersion;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;Cookie;true;toString;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;Cookie;false;Cookie;;;Argument[0..4];Argument[-1];taint",
        "jakarta.ws.rs.core;Cookie;false;valueOf;;;Argument[0];ReturnValue;taint"
      ]
  }
}

/**
 * Model NewCookie, a simple tuple type.
 */
private class NewCookieModel extends SummaryModelCsv {
  override predicate row(string row) {
    row =
      [
        "javax.ws.rs.core;NewCookie;true;getComment;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;NewCookie;true;getExpiry;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;NewCookie;true;getMaxAge;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;NewCookie;true;toCookie;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;NewCookie;false;NewCookie;;;Argument[0..9];Argument[-1];taint",
        "javax.ws.rs.core;NewCookie;false;valueOf;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;NewCookie;true;getComment;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;NewCookie;true;getExpiry;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;NewCookie;true;getMaxAge;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;NewCookie;true;toCookie;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;NewCookie;false;NewCookie;;;Argument[0..9];Argument[-1];taint",
        "jakarta.ws.rs.core;NewCookie;false;valueOf;;;Argument[0];ReturnValue;taint"
      ]
  }
}

/**
 * Model Form, a simple container type.
 */
private class FormModel extends SummaryModelCsv {
  override predicate row(string row) {
    row =
      [
        "javax.ws.rs.core;Form;false;Form;;;MapKey of Argument[0];Argument[-1];taint",
        "javax.ws.rs.core;Form;false;Form;;;Element of MapValue of Argument[0];Argument[-1];taint",
        "javax.ws.rs.core;Form;false;Form;;;Argument[0..1];Argument[-1];taint",
        "javax.ws.rs.core;Form;true;asMap;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;Form;true;param;;;Argument[0..1];Argument[-1];taint",
        "javax.ws.rs.core;Form;true;param;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;Form;false;Form;;;MapKey of Argument[0];Argument[-1];taint",
        "jakarta.ws.rs.core;Form;false;Form;;;Element of MapValue of Argument[0];Argument[-1];taint",
        "jakarta.ws.rs.core;Form;false;Form;;;Argument[0..1];Argument[-1];taint",
        "jakarta.ws.rs.core;Form;true;asMap;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;Form;true;param;;;Argument[0..1];Argument[-1];taint",
        "jakarta.ws.rs.core;Form;true;param;;;Argument[-1];ReturnValue;value"
      ]
  }
}

/**
 * Model GenericEntity, a wrapper for HTTP entities (e.g., documents).
 */
private class GenericEntityModel extends SummaryModelCsv {
  override predicate row(string row) {
    row =
      [
        "javax.ws.rs.core;GenericEntity;false;GenericEntity;;;Argument[0];Argument[-1];taint",
        "javax.ws.rs.core;GenericEntity;true;getEntity;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;GenericEntity;false;GenericEntity;;;Argument[0];Argument[-1];taint",
        "jakarta.ws.rs.core;GenericEntity;true;getEntity;;;Argument[-1];ReturnValue;taint"
      ]
  }
}

/**
 * Model MediaType, which provides accessors for elements of Content-Type and similar
 * media type specifications.
 */
private class MediaTypeModel extends SummaryModelCsv {
  override predicate row(string row) {
    row =
      [
        "javax.ws.rs.core;MediaType;false;MediaType;;;Argument[0..2];Argument[-1];taint",
        "javax.ws.rs.core;MediaType;true;getParameters;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;MediaType;true;getSubtype;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;MediaType;true;getType;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;MediaType;false;valueOf;;;Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;MediaType;true;withCharset;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;MediaType;false;MediaType;;;Argument[0..2];Argument[-1];taint",
        "jakarta.ws.rs.core;MediaType;true;getParameters;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;MediaType;true;getSubtype;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;MediaType;true;getType;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;MediaType;false;valueOf;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;MediaType;true;withCharset;;;Argument[-1];ReturnValue;taint"
      ]
  }
}

/**
 * Model UriBuilder, which provides a fluent interface to build a URI from components.
 */
private class UriBuilderModel extends SummaryModelCsv {
  override predicate row(string row) {
    row =
      [
        "javax.ws.rs.core;UriBuilder;true;build;;;ArrayElement of Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;build;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;buildFromEncoded;;;ArrayElement of Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;buildFromEncoded;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;buildFromEncodedMap;;;MapKey of Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;buildFromEncodedMap;;;MapValue of Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;buildFromEncodedMap;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;buildFromMap;;;MapKey of Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;buildFromMap;;;MapValue of Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;buildFromMap;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;clone;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;fragment;;;Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;fragment;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;UriBuilder;false;fromLink;;;Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;false;fromPath;;;Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;false;fromUri;;;Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;host;;;Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;host;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;UriBuilder;true;matrixParam;;;Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;matrixParam;;;ArrayElement of Argument[1];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;matrixParam;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;UriBuilder;true;path;;;Argument[0..1];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;path;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;UriBuilder;true;queryParam;;;Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;queryParam;;;ArrayElement of Argument[1];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;queryParam;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;UriBuilder;true;replaceMatrix;;;Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;replaceMatrix;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;UriBuilder;true;replaceMatrixParam;;;Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;replaceMatrixParam;;;ArrayElement of Argument[1];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;replaceMatrixParam;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;UriBuilder;true;replacePath;;;Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;replacePath;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;UriBuilder;true;replaceQuery;;;Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;replaceQuery;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;UriBuilder;true;replaceQueryParam;;;Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;replaceQueryParam;;;ArrayElement of Argument[1];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;replaceQueryParam;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;UriBuilder;true;resolveTemplate;;;Argument[0..2];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;resolveTemplate;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;UriBuilder;true;resolveTemplateFromEncoded;;;Argument[0..1];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;resolveTemplateFromEncoded;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;UriBuilder;true;resolveTemplates;;;MapKey of Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;resolveTemplates;;;MapValue of Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;resolveTemplates;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;UriBuilder;true;resolveTemplatesFromEncoded;;;MapKey of Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;resolveTemplatesFromEncoded;;;MapValue of Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;resolveTemplatesFromEncoded;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;UriBuilder;true;scheme;;;Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;scheme;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;UriBuilder;true;schemeSpecificPart;;;Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;schemeSpecificPart;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;UriBuilder;true;segment;;;ArrayElement of Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;segment;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;UriBuilder;true;toTemplate;;;Argument[-1];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;uri;;;Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;uri;;;Argument[-1];ReturnValue;value",
        "javax.ws.rs.core;UriBuilder;true;userInfo;;;Argument[0];ReturnValue;taint",
        "javax.ws.rs.core;UriBuilder;true;userInfo;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;UriBuilder;true;build;;;ArrayElement of Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;build;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;buildFromEncoded;;;ArrayElement of Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;buildFromEncoded;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;buildFromEncodedMap;;;MapKey of Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;buildFromEncodedMap;;;MapValue of Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;buildFromEncodedMap;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;buildFromMap;;;MapKey of Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;buildFromMap;;;MapValue of Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;buildFromMap;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;clone;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;fragment;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;fragment;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;UriBuilder;false;fromLink;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;false;fromPath;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;false;fromUri;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;host;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;host;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;UriBuilder;true;matrixParam;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;matrixParam;;;ArrayElement of Argument[1];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;matrixParam;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;UriBuilder;true;path;;;Argument[0..1];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;path;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;UriBuilder;true;queryParam;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;queryParam;;;ArrayElement of Argument[1];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;queryParam;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;UriBuilder;true;replaceMatrix;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;replaceMatrix;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;UriBuilder;true;replaceMatrixParam;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;replaceMatrixParam;;;ArrayElement of Argument[1];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;replaceMatrixParam;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;UriBuilder;true;replacePath;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;replacePath;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;UriBuilder;true;replaceQuery;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;replaceQuery;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;UriBuilder;true;replaceQueryParam;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;replaceQueryParam;;;ArrayElement of Argument[1];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;replaceQueryParam;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;UriBuilder;true;resolveTemplate;;;Argument[0..2];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;resolveTemplate;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;UriBuilder;true;resolveTemplateFromEncoded;;;Argument[0..1];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;resolveTemplateFromEncoded;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;UriBuilder;true;resolveTemplates;;;MapKey of Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;resolveTemplates;;;MapValue of Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;resolveTemplates;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;UriBuilder;true;resolveTemplatesFromEncoded;;;MapKey of Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;resolveTemplatesFromEncoded;;;MapValue of Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;resolveTemplatesFromEncoded;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;UriBuilder;true;scheme;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;scheme;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;UriBuilder;true;schemeSpecificPart;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;schemeSpecificPart;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;UriBuilder;true;segment;;;ArrayElement of Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;segment;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;UriBuilder;true;toTemplate;;;Argument[-1];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;uri;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;uri;;;Argument[-1];ReturnValue;value",
        "jakarta.ws.rs.core;UriBuilder;true;userInfo;;;Argument[0];ReturnValue;taint",
        "jakarta.ws.rs.core;UriBuilder;true;userInfo;;;Argument[-1];ReturnValue;value"
      ]
  }
}

private class JaxRsUrlOpenSink extends SinkModelCsv {
  override predicate row(string row) {
    row =
      [
        "javax.ws.rs.client;Client;true;target;;;Argument[0];open-url",
        "jakarta.ws.rs.client;Client;true;target;;;Argument[0];open-url"
      ]
  }
}

private predicate isXssVulnerableContentTypeExpr(Expr e) {
  isXssVulnerableContentType(getContentTypeString(e))
}

private predicate isXssSafeContentTypeExpr(Expr e) { isXssSafeContentType(getContentTypeString(e)) }

/**
 * Gets a builder expression or related type that is configured to use the given `contentType`.
 *
 * This could be an instance of `Response.ResponseBuilder`, `Variant`, `Variant.VariantListBuilder` or
 * a `List<Variant>`.
 *
 * This predicate is used to search forwards for response entities set after the content-type is configured.
 * It does not need to consider cases where the entity is set in the same call, or the entity has already
 * been set: these are handled by simple sanitization below.
 */
private DataFlow::Node getABuilderWithExplicitContentType(Expr contentType) {
  // Base case: ResponseBuilder.type(contentType)
  result.asExpr() =
    any(MethodAccess ma |
      ma.getCallee().hasQualifiedName(getAJaxRsPackage("core"), "Response$ResponseBuilder", "type") and
      contentType = ma.getArgument(0)
    )
  or
  // Base case: new Variant(contentType, ...)
  result.asExpr() =
    any(ClassInstanceExpr cie |
      cie.getConstructedType().hasQualifiedName(getAJaxRsPackage("core"), "Variant") and
      contentType = cie.getArgument(0)
    )
  or
  // Base case: Variant[.VariantListBuilder].mediaTypes(...)
  result.asExpr() =
    any(MethodAccess ma |
      ma.getCallee()
          .hasQualifiedName(getAJaxRsPackage("core"), ["Variant", "Variant$VariantListBuilder"],
            "mediaTypes") and
      contentType = ma.getAnArgument()
    )
  or
  // Recursive case: propagate through variant list building:
  result.asExpr() =
    any(MethodAccess ma |
      (
        ma.getType()
            .(RefType)
            .hasQualifiedName(getAJaxRsPackage("core"), "Variant$VariantListBuilder")
        or
        ma.getMethod()
            .hasQualifiedName(getAJaxRsPackage("core"), "Variant$VariantListBuilder", "build")
      ) and
      [ma.getAnArgument(), ma.getQualifier()] =
        getABuilderWithExplicitContentType(contentType).asExpr()
    )
  or
  // Recursive case: propagate through a List.get operation
  result.asExpr() =
    any(MethodAccess ma |
      ma.getMethod().hasQualifiedName("java.util", "List<Variant>", "get") and
      ma.getQualifier() = getABuilderWithExplicitContentType(contentType).asExpr()
    )
  or
  // Recursive case: propagate through Response.ResponseBuilder operations, including the `variant(...)` operation.
  result.asExpr() =
    any(MethodAccess ma |
      ma.getType().(RefType).hasQualifiedName(getAJaxRsPackage("core"), "Response$ResponseBuilder") and
      [ma.getQualifier(), ma.getArgument(0)] =
        getABuilderWithExplicitContentType(contentType).asExpr()
    )
  or
  // Recursive case: ordinary local dataflow
  DataFlow::localFlowStep(getABuilderWithExplicitContentType(contentType), result)
}

private DataFlow::Node getASanitizedBuilder() {
  result = getABuilderWithExplicitContentType(any(Expr e | isXssSafeContentTypeExpr(e)))
}

private DataFlow::Node getAVulnerableBuilder() {
  result = getABuilderWithExplicitContentType(any(Expr e | isXssVulnerableContentTypeExpr(e)))
}

/**
 * A response builder sanitized by setting a safe content type.
 *
 * The content type could be set before the `entity(...)` call that needs sanitizing
 * (e.g. `Response.ok().type("application/json").entity(sanitizeMe)`)
 * or at the same time (e.g. `Response.ok(sanitizeMe, "application/json")`
 * or the content-type could be set afterwards (e.g. `Response.ok().entity(userControlled).type("application/json")`)
 *
 * This differs from `getASanitizedBuilder` in that we also include functions that must set the entity
 * at the same time, or the entity must already have been set, so propagating forwards to sanitize future
 * build steps is not necessary.
 */
private class SanitizedResponseBuilder extends XssSanitizer {
  SanitizedResponseBuilder() {
    // e.g. sanitizeMe.type("application/json")
    this = getASanitizedBuilder()
    or
    this.asExpr() =
      any(MethodAccess ma |
        ma.getMethod().hasQualifiedName(getAJaxRsPackage("core"), "Response", "ok") and
        (
          // e.g. Response.ok(sanitizeMe, new Variant("application/json", ...))
          ma.getArgument(1) = getASanitizedBuilder().asExpr()
          or
          // e.g. Response.ok(sanitizeMe, "application/json")
          isXssSafeContentTypeExpr(ma.getArgument(1))
        )
      )
  }
}

/**
 * An entity call that serves as a sink and barrier because it has a vulnerable content-type set.
 *
 * We flag these as direct sinks because otherwise it may be sanitized when it reaches a resource
 * method with a safe-looking `@Produces` annotation. They are barriers because otherwise if the
 * resource method does *not* have a safe-looking `@Produces` annotation then it would be doubly
 * reported, once at the `entity(...)` call and once on return from the resource method.
 */
private class VulnerableEntity extends XssSinkBarrier {
  VulnerableEntity() {
    this.asExpr() =
      any(MethodAccess ma |
        (
          // Vulnerable content-type already set:
          ma.getQualifier() = getAVulnerableBuilder().asExpr()
          or
          // Vulnerable content-type set in the future:
          getAVulnerableBuilder().asExpr().(MethodAccess).getQualifier*() = ma
        ) and
        ma.getMethod().hasName("entity")
      ).getArgument(0)
    or
    this.asExpr() =
      any(MethodAccess ma |
        (
          isXssVulnerableContentTypeExpr(ma.getArgument(1))
          or
          ma.getArgument(1) = getAVulnerableBuilder().asExpr()
        ) and
        ma.getMethod().hasName("ok")
      ).getArgument(0)
  }
}
